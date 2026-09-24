#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: setup_warp_singbox.sh
# 作用: 一键配置 Cloudflare WARP (SOCKS5 本地代理模式) 并将其作为 sing-box 
#       的 Google / YouTube / Gemini 分流出口，彻底解决 IP 送中问题。
# 支持系统: Debian 11/12+, Ubuntu 20.04/22.04/24.04+ (x86_64 / arm64)
# ==============================================================================

set -euo pipefail

# 默认配置参数
WARP_PORT=40000
SINGBOX_CONFIG_PATH="${1:-}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_succ() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# 1. 检查权限
if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此脚本！"
fi

# 2. 自动定位 sing-box 配置文件与系统服务
if [ -z "$SINGBOX_CONFIG_PATH" ]; then
    if [ -f "/etc/vless-reality/singbox.json" ]; then
        SINGBOX_CONFIG_PATH="/etc/vless-reality/singbox.json"
    elif [ -f "/etc/sing-box/config.json" ]; then
        SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"
    elif [ -f "/usr/local/etc/sing-box/config.json" ]; then
        SINGBOX_CONFIG_PATH="/usr/local/etc/sing-box/config.json"
    else
        log_fail "未自动发现 sing-box 配置文件，请手动指定路径：bash $0 /path/to/singbox.json"
    fi
fi

if [ ! -f "$SINGBOX_CONFIG_PATH" ]; then
    log_fail "指定的配置文件不存在: $SINGBOX_CONFIG_PATH"
fi
CONFIG_DIR="$(dirname "$SINGBOX_CONFIG_PATH")"
log_info "目标配置文件: $SINGBOX_CONFIG_PATH"

# 自动判定 systemd 服务名
SINGBOX_SERVICE=""
if systemctl cat vless-singbox.service >/dev/null 2>&1; then
    SINGBOX_SERVICE="vless-singbox.service"
elif systemctl cat sing-box.service >/dev/null 2>&1; then
    SINGBOX_SERVICE="sing-box.service"
else
    log_warn "未找到常见名称的 sing-box systemd 服务 (vless-singbox / sing-box)"
fi

# 3. 安装必要基础工具
log_info "检查并安装基础依赖 (curl, gpg, python3, lsb-release)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gpg python3 lsb-release ca-certificates >/dev/null

# 4. 安装 Cloudflare WARP 官方客户端
if ! command -v warp-cli >/dev/null 2>&1; then
    log_info "正在配置 Cloudflare 官方软件源..."
    CODENAME="$(lsb_release -cs)"
    GPG_KEY="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output "$GPG_KEY"
    echo "deb [signed-by=$GPG_KEY] https://pkg.cloudflareclient.com/ $CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
    
    log_info "正在安装 cloudflare-warp..."
    apt-get update -qq
    apt-get install -y -qq cloudflare-warp >/dev/null
    log_succ "cloudflare-warp 安装完成。"
else
    log_info "检测到 warp-cli 已安装，跳过安装步骤。"
fi

# 5. 配置 WARP 为本地 SOCKS5 代理模式 (监听 127.0.0.1:40000)
log_info "配置 WARP 代理模式及端口 ${WARP_PORT}..."
systemctl enable --now warp-svc >/dev/null 2>&1 || true

# 注册客户端 (若已注册则忽略错误)
warp-cli --accept-tos registration new >/dev/null 2>&1 || true

# 设置为 proxy 模式并指定端口
warp-cli --accept-tos mode proxy >/dev/null
warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null
warp-cli --accept-tos connect >/dev/null

log_info "等待 WARP 连接建立..."
for i in {1..10}; do
    WARP_STATUS="$(warp-cli --accept-tos --no-paginate status 2>/dev/null || true)"
    if echo "$WARP_STATUS" | grep -q "Connected"; then
        log_succ "WARP 连接成功！"
        break
    fi
    sleep 1
done

# 6. 下载 / 更新分流规则集
log_info "下载最新的 Google / YouTube 规则集到 $CONFIG_DIR ..."
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs -o "$CONFIG_DIR/geosite-google.srs"
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs -o "$CONFIG_DIR/geosite-youtube.srs"
curl -sSL https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs -o "$CONFIG_DIR/geoip-google.srs"
log_succ "规则集文件准备就绪。"

# 7. 备份并更新 sing-box 配置文件
BACKUP_PATH="${SINGBOX_CONFIG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$SINGBOX_CONFIG_PATH" "$BACKUP_PATH"
log_info "原配置已备份至: $BACKUP_PATH"

log_info "合并分流规则到 sing-box 配置..."
python3 - <<EOF
import json
import sys

config_path = "$SINGBOX_CONFIG_PATH"
config_dir = "$CONFIG_DIR"
warp_port = int("$WARP_PORT")

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

# 1. 确保 outbounds 中包含 warp-out
outbounds = data.get("outbounds", [])
warp_tag = "warp-out"
if not any(o.get("tag") == warp_tag for o in outbounds):
    outbounds.append({
        "type": "socks",
        "tag": warp_tag,
        "server": "127.0.0.1",
        "server_port": warp_port
    })
data["outbounds"] = outbounds

# 2. 确保 route 存在
route = data.get("route", {})
rules = route.get("rules", [])
rule_set = route.get("rule_set", [])

# 确保在 rules 最前部开启嗅探
if not any(r.get("action") == "sniff" for r in rules):
    rules.insert(0, {"action": "sniff"})

# 确保拦截 Google / YouTube 的 QUIC (UDP 443) 流量
# 原因：WARP 本地 SOCKS5 不支持 UDP，且 Chrome 默认优先使用 QUIC (UDP 443)。
# 若不拦截 QUIC，浏览器对 YouTube 的请求会绕过 WARP 走直连导致依然“送中”。拦截后浏览器会自动平滑降级为 TCP (TLS 1.3 / HTTP2) 经由 WARP 转发。
quic_rule = {
    "network": "udp",
    "port": 443,
    "rule_set": ["geosite-google", "geosite-youtube"],
    "action": "reject"
}
# 避免重复插入
has_quic_reject = any(
    r.get("action") == "reject" and r.get("network") == "udp" and 443 in ([r.get("port")] if isinstance(r.get("port"), int) else r.get("port", []))
    for r in rules
)
if not has_quic_reject:
    # 插入在 sniff 之后
    idx = 1 if len(rules) > 0 and rules[0].get("action") == "sniff" else 0
    rules.insert(idx, quic_rule)

# 确保 Google / YouTube / GeoIP 路由规则存在 (转发至 warp-out)
target_rule_sets = ["geosite-google", "geosite-youtube", "geoip-google"]
rule_exists = False
for r in rules:
    # 忽略用于拦截 QUIC 的 reject 规则
    if r.get("action") == "reject":
        continue
    rs = r.get("rule_set", [])
    if isinstance(rs, list) and any(x in rs for x in ["geosite-google", "geosite-youtube"]):
        for t in target_rule_sets:
            if t not in rs:
                rs.append(t)
        r["outbound"] = warp_tag
        rule_exists = True
        break

if not rule_exists:
    rules.append({
        "rule_set": target_rule_sets,
        "outbound": warp_tag
    })
route["rules"] = rules

# 3. 确保本地 rule_set 定义存在
rule_defs = [
    {"tag": "geosite-google", "path": f"{config_dir}/geosite-google.srs"},
    {"tag": "geosite-youtube", "path": f"{config_dir}/geosite-youtube.srs"},
    {"tag": "geoip-google", "path": f"{config_dir}/geoip-google.srs"}
]
for rdef in rule_defs:
    tag = rdef["tag"]
    if not any(rs.get("tag") == tag for rs in rule_set):
        rule_set.append({
            "type": "local",
            "tag": tag,
            "format": "binary",
            "path": rdef["path"]
        })
route["rule_set"] = rule_set
data["route"] = route

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

# 8. 语法安全校验
log_info "正在检验 sing-box 配置文件语法..."
if sing-box check -c "$SINGBOX_CONFIG_PATH" >/dev/null 2>&1; then
    log_succ "sing-box 配置文件语法检验通过！"
else
    log_warn "配置语法检验失败！正在回滚原备份配置..."
    cp -a "$BACKUP_PATH" "$SINGBOX_CONFIG_PATH"
    sing-box check -c "$SINGBOX_CONFIG_PATH"
    log_fail "已自动回滚备份，请检查原配置。"
fi

# 9. 重启 sing-box 服务
if [ -n "$SINGBOX_SERVICE" ]; then
    log_info "正在重启服务: $SINGBOX_SERVICE ..."
    systemctl restart "$SINGBOX_SERVICE"
    sleep 2
    if systemctl is-active "$SINGBOX_SERVICE" >/dev/null; then
        log_succ "$SINGBOX_SERVICE 重启成功并处于运行状态！"
    else
        log_fail "$SINGBOX_SERVICE 启动异常，请检查 systemctl status $SINGBOX_SERVICE"
    fi
fi

# 10. 创建规则集定期更新脚本与 WARP 状态检查脚本
UPDATE_SCRIPT="$CONFIG_DIR/update-rules.sh"
cat << EOF > "$UPDATE_SCRIPT"
#!/usr/bin/env bash
set -e
echo "[*] Updating rule sets in $CONFIG_DIR ..."
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs -o "$CONFIG_DIR/geosite-google.srs"
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs -o "$CONFIG_DIR/geosite-youtube.srs"
curl -sSL https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs -o "$CONFIG_DIR/geoip-google.srs"
if [ -n "$SINGBOX_SERVICE" ]; then
    systemctl restart "$SINGBOX_SERVICE"
fi
echo "[*] Rule sets updated and service restarted successfully."
EOF
chmod +x "$UPDATE_SCRIPT"

CHECK_SCRIPT="$CONFIG_DIR/check-warp.sh"
cat << EOF > "$CHECK_SCRIPT"
#!/usr/bin/env bash
WARP_PORT="\${1:-$WARP_PORT}"
python3 - << 'PYEOF'
import urllib.request
import urllib.parse
import json
import base64
import subprocess
import sys
import re

warp_port = int(sys.argv[1]) if len(sys.argv) > 1 else $WARP_PORT
proxy = f"socks5h://127.0.0.1:{warp_port}"

def fetch_ip(proxy=None, ip_version=4):
    url = f"https://ipv{ip_version}.icanhazip.com"
    cmd = ["curl", "-s", "--max-time", "5"]
    if proxy:
        cmd.extend(["-x", proxy])
    cmd.append(url)
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=6)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass
    return None

def check_youtube_region(proxy=None, ip_version=None):
    cmd = ["curl", "-sI", "--max-time", "8"]
    if ip_version == 4:
        cmd.append("-4")
    elif ip_version == 6:
        cmd.append("-6")
    if proxy:
        cmd.extend(["-x", proxy])
    cmd.append("https://www.youtube.com")
    region = None
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        for line in res.stdout.splitlines():
            if "VISITOR_PRIVACY_METADATA=" in line:
                token = line.split("VISITOR_PRIVACY_METADATA=")[1].split(";")[0].strip()
                token = urllib.parse.unquote(token)
                raw = base64.b64decode(token)
                if len(raw) >= 4 and raw[0] == 0x0a:
                    cc_len = raw[1]
                    region = raw[2:2+cc_len].decode("ascii", errors="ignore").upper()
    except Exception:
        pass

    # 深度检测: 检查 YouTube Premium 页面
    # 很多机房 IP 的 Privacy Cookie 默认显示 US，但其实际归属地可通过 Premium 页面中的 countryCode / GL 精准获取；
    # 若被 Google 标记送中，页面则会直接提示不可用。
    p_cmd = ["curl", "-sL", "--max-time", "8"]
    if ip_version == 4:
        p_cmd.append("-4")
    elif ip_version == 6:
        p_cmd.append("-6")
    if proxy:
        p_cmd.extend(["-x", proxy])
    p_cmd.extend(["-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)", "https://www.youtube.com/premium"])
    try:
        p_res = subprocess.run(p_cmd, capture_output=True, text=True, timeout=10)
        if "YouTube Premium is not available in your country" in p_res.stdout or "Premium is not available" in p_res.stdout:
            return "CN"
        
        # 优先提取精准的 countryCode (如 JP, US, SG, HK 等)
        cc_match = re.search(r'\"countryCode\":\s*\"([A-Z]{2})\"', p_res.stdout)
        if cc_match:
            return cc_match.group(1)

        # 其次提取 INNERTUBE_CONTEXT_GL / GL
        gl_match = re.search(r'\"(?:GL|INNERTUBE_CONTEXT_GL)\":\s*\"([A-Z]{2})\"', p_res.stdout)
        if gl_match:
            return gl_match.group(1)
    except Exception:
        pass

    return region or "UNKNOWN"

def check_google_redirect(proxy=None):
    cmd = ["curl", "-sI", "--max-time", "8"]
    if proxy:
        cmd.extend(["-x", proxy])
    cmd.append("https://www.google.com")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        for line in res.stdout.splitlines():
            if line.lower().startswith("location:"):
                loc = line.split(":", 1)[1].strip()
                if "google.com.hk" in loc:
                    return "CN (重定向至 google.com.hk / 已送中)"
                return f"重定向至 {loc}"
        if "HTTP/2 200" in res.stdout or "HTTP/1.1 200" in res.stdout:
            return "正常 (未送中，停留在 google.com)"
    except Exception:
        pass
    return "检测超时/未知"

def format_native_yt(region):
    if not region or region == "UNKNOWN":
        return "未知/不可达"
    if region == "CN":
        return "\033[31mCN (已送中)\033[0m"
    return f"\033[32m{region}\033[0m"

# 检查 WARP IP
v4_ip = fetch_ip(proxy, 4)
v6_ip = fetch_ip(proxy, 6)
proxy_alive = bool(v4_ip or v6_ip)

if proxy_alive:
    yt_region = check_youtube_region(proxy)
    google_status = check_google_redirect(proxy)
else:
    yt_region = None
    google_status = f"代理未就绪 (端口 {warp_port} 无法连通)"

# 原生 IP 及属地对比 (分别检测 v4 与 v6)
native_v4 = fetch_ip(None, 4)
native_yt_v4 = check_youtube_region(None, 4) if native_v4 else None

native_v6 = fetch_ip(None, 6)
native_yt_v6 = check_youtube_region(None, 6) if native_v6 else None

print("\n" + "="*62)
print("       Cloudflare WARP 出口 IP 与属地分流检测报告")
print("="*62)
print(f" WARP IPv4 地址 : {v4_ip if v4_ip else '未分配或代理未就绪 (端口 ' + str(warp_port) + ')'}")
print(f" WARP IPv6 地址 : {v6_ip if v6_ip else '未分配或不可达'}")
print("-" * 62)
print(f" Google 搜索状态: {google_status}")

if not proxy_alive:
    print(f" YouTube 判定区 : \033[33m代理未就绪 (请先安装或启动 Cloudflare WARP)\033[0m")
elif yt_region == "CN":
    print(f" YouTube 判定区 : \033[31m{yt_region} (警告：当前 WARP IP 同样被识别为送中！)\033[0m")
    print("                 -> 可尝试执行: warp-cli disconnect && warp-cli connect 刷新 IP")
elif yt_region and yt_region != "UNKNOWN":
    print(f" YouTube 判定区 : \033[32m{yt_region} (正常，解除送中，支持 YouTube Premium)\033[0m")
else:
    print(f" YouTube 判定区 : \033[33mUNKNOWN (检测超时或响应解析失败)\033[0m")

print("-" * 62)
v4_str = f"{native_v4} (YouTube: {format_native_yt(native_yt_v4)})" if native_v4 else "未分配或不可达"
v6_str = f"{native_v6} (YouTube: {format_native_yt(native_yt_v6)})" if native_v6 else "未分配或不可达"
print(f" 原生 IPv4 出口 : {v4_str}")
print(f" 原生 IPv6 出口 : {v6_str}")
print("="*62 + "\n")
PYEOF
EOF
chmod +x "$CHECK_SCRIPT"

# 11. 检查 WARP 出口 IP 及其属地，若不幸分到送中 IP 则自动重拨刷新 (最多尝试 3 次)
log_info "正在检验 WARP 出口 IP 及 Google/YouTube 属地判定..."
for attempt in 1 2 3; do
    YT_CHECK="$(curl -sI --max-time 8 -x socks5h://127.0.0.1:${WARP_PORT} https://www.youtube.com | grep -i "VISITOR_PRIVACY_METADATA=" || true)"
    CURRENT_REGION=""
    if [ -n "$YT_CHECK" ]; then
        RAW_TOKEN="$(echo "$YT_CHECK" | sed -n 's/.*VISITOR_PRIVACY_METADATA=\([^;]*\).*/\1/p')"
        CURRENT_REGION="$(python3 -c "import urllib.parse, base64; raw=base64.b64decode(urllib.parse.unquote('$RAW_TOKEN')); print(raw[2:2+raw[1]].decode('ascii', errors='ignore'))" 2>/dev/null || true)"
    fi
    PREMIUM_BLOCKED="$(curl -sL --max-time 8 -x socks5h://127.0.0.1:${WARP_PORT} -H 'User-Agent: Mozilla/5.0' https://www.youtube.com/premium | grep -o -E 'YouTube Premium is not available in your country|Premium is not available' || true)"
    if [ -n "$PREMIUM_BLOCKED" ]; then
        CURRENT_REGION="CN"
    fi

    if [ "$CURRENT_REGION" = "CN" ]; then
        if [ "$attempt" -lt 3 ]; then
            log_warn "当前分配到的 WARP IP 被 YouTube 识别为 CN (送中)，正在自动重拨刷新 WARP IP (第 $attempt/3 次)..."
            warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
            sleep 1
            warp-cli --accept-tos connect >/dev/null 2>&1 || true
            sleep 3
        else
            log_warn "重拨 3 次后 WARP IP 仍处于 CN 地区，稍后可通过运行 $CONFIG_DIR/check-warp.sh 再次查看。"
        fi
    else
        break
    fi
done

# 打印最终检测报告
bash "$CHECK_SCRIPT"

echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  部署成功！已将 Google/YouTube 流量自动分流至 Cloudflare WARP  ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "配置文件: ${CYAN}$SINGBOX_CONFIG_PATH${NC}"
echo -e "备份文件: ${YELLOW}$BACKUP_PATH${NC}"
echo -e "WARP 端口: ${CYAN}127.0.0.1:${WARP_PORT} (SOCKS5)${NC}"
echo -e "更新脚本: ${CYAN}$UPDATE_SCRIPT${NC}"
echo -e "检测脚本: ${CYAN}$CHECK_SCRIPT${NC}"
echo ""
echo -e "${YELLOW}[注意] 如果客户端浏览器（Chrome 等）未立即生效，请：${NC}"
echo -e "  1. 打开浏览器【无痕窗口】或清除 youtube.com 的 Cookie 缓存；"
echo -e "  2. 关闭浏览器并重新打开（释放此前的长连接与 QUIC 会话）；"
echo -e "  3. 确认已在 YouTube 网页中正常登录你的 Google 账号。"
echo ""
