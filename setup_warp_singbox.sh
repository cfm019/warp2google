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

# 校验本地 SOCKS5 出口
WARP_TEST="$(curl -s -x "socks5://127.0.0.1:${WARP_PORT}" https://api.ip.sb/geoip || true)"
if echo "$WARP_TEST" | grep -qi "Cloudflare"; then
    WARP_IP="$(echo "$WARP_TEST" | grep -oP '(?<="ip":")[^"]+' || true)"
    WARP_COUNTRY="$(echo "$WARP_TEST" | grep -oP '(?<="country":")[^"]+' || true)"
    log_succ "WARP SOCKS5 测试正常 (出口 IP: $WARP_IP, 地区: $WARP_COUNTRY)"
else
    log_warn "WARP SOCKS5 暂未返回 Cloudflare 信息，可能正在建立连接中..."
fi

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

# 确保 Google / YouTube / GeoIP 路由规则存在
target_rule_sets = ["geosite-google", "geosite-youtube", "geoip-google"]
rule_exists = False
for r in rules:
    rs = r.get("rule_set", [])
    if isinstance(rs, list) and any(x in rs for x in ["geosite-google", "geosite-youtube"]):
        # 更新该规则指向 warp-out 并补齐
        for t in target_rule_sets:
            if t not in rs:
                rs.append(t)
        r["outbound"] = warp_tag
        rule_exists = True
        break

if not rule_exists:
    # 插入在嗅探动作之后
    insert_idx = 1 if len(rules) > 0 and rules[0].get("action") == "sniff" else 0
    rules.insert(insert_idx, {
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

# 10. 创建规则集定期更新脚本
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
log_succ "维护更新脚本已生成: $UPDATE_SCRIPT"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  部署成功！已将 Google/YouTube 流量自动分流至 Cloudflare WARP  ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "配置文件: ${CYAN}$SINGBOX_CONFIG_PATH${NC}"
echo -e "备份文件: ${YELLOW}$BACKUP_PATH${NC}"
echo -e "WARP 端口: ${CYAN}127.0.0.1:${WARP_PORT} (SOCKS5)${NC}"
echo -e "更新脚本: ${CYAN}$UPDATE_SCRIPT${NC}"
echo ""
