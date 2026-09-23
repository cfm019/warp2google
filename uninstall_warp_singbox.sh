#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: uninstall_warp_singbox.sh
# 作用: 一键卸载 Cloudflare WARP 并完全清理 sing-box 中的分流规则与关联文件，
#       将所有 Google / YouTube / Gemini 流量恢复为 VPS 原生出口直连。
# 支持参数:
#   bash uninstall_warp_singbox.sh [/path/to/singbox.json] [--keep-warp]
# ==============================================================================

set -euo pipefail

# 参数解析
KEEP_WARP=false
SINGBOX_CONFIG_PATH=""

for arg in "$@"; do
    case "$arg" in
        --keep-warp)
            KEEP_WARP=true
            ;;
        *)
            if [ -z "$SINGBOX_CONFIG_PATH" ]; then
                SINGBOX_CONFIG_PATH="$arg"
            fi
            ;;
    esac
done

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

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_fail "请使用 root 用户运行此卸载脚本！"
fi

echo -e "${YELLOW}================================================================${NC}"
echo -e "${YELLOW}           正在准备卸载 Cloudflare WARP & 清理分流配置           ${NC}"
echo -e "${YELLOW}================================================================${NC}"

# 2. 自动定位 sing-box 配置文件与系统服务
if [ -z "$SINGBOX_CONFIG_PATH" ]; then
    if [ -f "/etc/vless-reality/singbox.json" ]; then
        SINGBOX_CONFIG_PATH="/etc/vless-reality/singbox.json"
    elif [ -f "/etc/sing-box/config.json" ]; then
        SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"
    elif [ -f "/usr/local/etc/sing-box/config.json" ]; then
        SINGBOX_CONFIG_PATH="/usr/local/etc/sing-box/config.json"
    else
        log_warn "未自动发现常见的 sing-box 配置文件路径，跳过配置文件清理。"
    fi
fi

SINGBOX_SERVICE=""
if systemctl cat vless-singbox.service >/dev/null 2>&1; then
    SINGBOX_SERVICE="vless-singbox.service"
elif systemctl cat sing-box.service >/dev/null 2>&1; then
    SINGBOX_SERVICE="sing-box.service"
else
    log_warn "未找到常见名称的 sing-box systemd 服务 (vless-singbox / sing-box)"
fi

# 3. 清理 sing-box 配置文件中的 WARP 出口与路由规则
BACKUP_PATH=""
if [ -n "$SINGBOX_CONFIG_PATH" ] && [ -f "$SINGBOX_CONFIG_PATH" ]; then
    CONFIG_DIR="$(dirname "$SINGBOX_CONFIG_PATH")"
    log_info "正在清理配置文件: $SINGBOX_CONFIG_PATH ..."
    
    # 卸载前先备份当前配置
    BACKUP_PATH="${SINGBOX_CONFIG_PATH}.bak.uninstall.$(date +%Y%m%d_%H%M%S)"
    cp -a "$SINGBOX_CONFIG_PATH" "$BACKUP_PATH"
    log_info "原配置已备份至: $BACKUP_PATH"

    python3 - <<EOF
import json
import sys

config_path = "$SINGBOX_CONFIG_PATH"

try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"读取配置失败: {e}", file=sys.stderr)
    sys.exit(1)

# 1. 清理 outbounds 中的 warp-out
outbounds = data.get("outbounds", [])
data["outbounds"] = [o for o in outbounds if o.get("tag") != "warp-out"]

# 2. 清理 route.rules
target_tags = {"geosite-google", "geosite-youtube", "geoip-google"}
route = data.get("route", {})
rules = route.get("rules", [])
cleaned_rules = []

for r in rules:
    # 过滤针对 Google/YouTube 的 QUIC reject 规则
    if r.get("action") == "reject" and r.get("network") == "udp":
        rs = r.get("rule_set", [])
        if isinstance(rs, list) and any(x in target_tags for x in rs):
            continue
        if isinstance(rs, str) and rs in target_tags:
            continue

    # 过滤指向 warp-out 的路由规则
    if r.get("outbound") == "warp-out":
        continue

    # 处理含有 rule_set 的其他规则
    if "rule_set" in r:
        rs = r.get("rule_set")
        if isinstance(rs, list):
            new_rs = [x for x in rs if x not in target_tags]
            if not new_rs:
                del r["rule_set"]
                matchers = [k for k in r.keys() if k not in ("outbound", "action")]
                if not matchers:
                    continue
            else:
                r["rule_set"] = new_rs
        elif isinstance(rs, str) and rs in target_tags:
            del r["rule_set"]
            matchers = [k for k in r.keys() if k not in ("outbound", "action")]
            if not matchers:
                continue

    cleaned_rules.append(r)

route["rules"] = cleaned_rules

# 3. 清理 route.rule_set
rule_sets = route.get("rule_set", [])
route["rule_set"] = [rs for rs in rule_sets if rs.get("tag") not in target_tags]

data["route"] = route

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("配置规则清理完成。")
EOF

    # 语法检验
    log_info "正在检验 sing-box 配置文件语法..."
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$SINGBOX_CONFIG_PATH" >/dev/null 2>&1; then
            log_succ "sing-box 配置文件语法检验通过！"
        else
            log_warn "配置语法检验失败！正在回滚配置..."
            cp -a "$BACKUP_PATH" "$SINGBOX_CONFIG_PATH"
            log_fail "语法检验失败，已自动回滚备份，未对原配置造成破坏。"
        fi
    fi

    # 4. 删除下载的规则集文件与维护脚本
    log_info "正在删除分流规则集文件与辅助脚本..."
    rm -f "$CONFIG_DIR/geosite-google.srs" \
          "$CONFIG_DIR/geosite-youtube.srs" \
          "$CONFIG_DIR/geoip-google.srs" \
          "$CONFIG_DIR/update-rules.sh" \
          "$CONFIG_DIR/check-warp.sh"
    log_succ "规则集与辅助脚本已清理。"

    # 5. 清理 crontab 定时任务（若存在 update-rules.sh）
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "update-rules.sh"; then
            log_info "检测到 crontab 中存在规则集自动更新任务，正在清理..."
            crontab -l 2>/dev/null | grep -v "update-rules.sh" | crontab - || true
            log_succ "crontab 定时任务清理完成。"
        fi
    fi

    # 6. 重启 sing-box 服务
    if [ -n "$SINGBOX_SERVICE" ]; then
        log_info "正在重启 sing-box 服务 ($SINGBOX_SERVICE)..."
        systemctl restart "$SINGBOX_SERVICE" || true
        sleep 1
        if systemctl is-active "$SINGBOX_SERVICE" >/dev/null 2>&1; then
            log_succ "$SINGBOX_SERVICE 重启成功，已恢复 VPS 原生出口直连。"
        else
            log_warn "$SINGBOX_SERVICE 状态异常，请执行 systemctl status $SINGBOX_SERVICE 查看日志。"
        fi
    fi
else
    log_info "未指定配置文件或文件不存在，跳过 sing-box 规则清理。"
fi

# 7. 停止并注销 Cloudflare WARP
if command -v warp-cli >/dev/null 2>&1; then
    log_info "正在断开 WARP 连接并注销设备注册信息..."
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
fi

if systemctl cat warp-svc.service >/dev/null 2>&1; then
    log_info "正在停止并禁用 warp-svc 服务..."
    systemctl stop warp-svc >/dev/null 2>&1 || true
    systemctl disable warp-svc >/dev/null 2>&1 || true
fi

# 8. 卸载 Cloudflare WARP 软件包（如未指定 --keep-warp）
if [ "$KEEP_WARP" = true ]; then
    log_info "检测到 --keep-warp 参数，保留 cloudflare-warp 客户端。"
else
    log_info "正在卸载 cloudflare-warp 软件包及 APT 源..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq cloudflare-warp >/dev/null 2>&1 || apt-get remove -y -qq cloudflare-warp >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    
    # 清理官方源与密钥
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -rf /var/lib/cloudflare-warp
    log_succ "cloudflare-warp 软件包已完全卸载。"
fi

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}             卸载与清理完成！所有流量已恢复原生直连             ${NC}"
echo -e "${GREEN}================================================================${NC}"
if [ -n "$SINGBOX_CONFIG_PATH" ] && [ -n "$BACKUP_PATH" ]; then
    echo -e "配置文件: ${CYAN}$SINGBOX_CONFIG_PATH${NC}"
    echo -e "备份文件: ${YELLOW}$BACKUP_PATH${NC}"
fi
echo ""
