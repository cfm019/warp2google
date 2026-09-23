# Cloudflare WARP + sing-box 优雅解决出口 IP 送中方案

本方案与自动化脚本专为解决自建节点、境外 VPS 出口 IP 遭遇 **“Google 送中”**（被识别为中国大陆导致 Google 搜索强制跳转、Gemini/Google One 无法使用、YouTube Premium 画中画与后台播放受限等）而设计。

通过配置官方 **Cloudflare WARP 运行于本地 SOCKS5 代理模式**，并结合 **sing-box 规则路由分流**，实现：
- **目标流量精准分流**：Google、YouTube、Gemini 相关域名及 IP 流量经由 Cloudflare WARP 干净出口送达；
- **原生速度与低延迟**：其他常规流量仍走 VPS 原生网络出口，避免无谓的全局套娃与性能损耗；
- **安全与零失联风险**：WARP 仅监听于本地回环地址（`127.0.0.1:40000`），不接管 VPS 主网关与路由表，绝不影响 SSH 远程连接与原有服务。

---

## 架构拓扑

```mermaid
flowchart LR
    Client["客户端 (手机 / 电脑)"] -->|VLESS / Hysteria2 / SS| Singbox["sing-box 代理服务端"]
    
    Singbox -->|Sniff 域名 & 规则匹配| Router{"路由分流 (Route)"}
    
    Router -->|Google / YouTube / Gemini| Warp["WARP 本地代理 (127.0.0.1:40000)"]
    Router -->|其他常规流量| Direct["原生出口 (Direct)"]
    
    Warp -->|Cloudflare 干净 IP 出口| TargetGoogle["Google / YouTube / Gemini"]
    Direct -->|VPS 原生 IP 出口| TargetWeb["常规互联网"]
```

---

## 一键自动化安装

适用于 **Debian 11/12+** 或 **Ubuntu 20.04/22.04/24.04+** 系统。

### 方式 1：直接在远程服务器上运行
登录你的 VPS 执行以下命令：
```bash
curl -fsSL https://raw.githubusercontent.com/cfm019/warp2google/main/setup_warp_singbox.sh | sudo bash
```
或下载本地执行：
```bash
sudo bash setup_warp_singbox.sh
```

### 方式 2：从控制机通过 SSH 一键推送到远程服务器
如果你在本地管理多台服务器，可直接通过标准 SSH 管道推送到目标机器执行：
```bash
ssh root@<YOUR_SERVER_IP> "bash -s" < setup_warp_singbox.sh
```

> [!TIP]
> 脚本具备**幂等性**与**语法回滚机制**：
> - 自动查找常见配置文件路径（如 `/etc/vless-reality/singbox.json` 或 `/etc/sing-box/config.json`）；
> - 修改前自动创建带时间戳的 `.bak` 备份文件；
> - 修改后自动调用 `sing-box check` 进行语法自检，一旦出错自动瞬间回滚，确保节点安全。

---

## 手动配置指引 (逐步拆解)

若你想手动配置或集成到现有体系中，可按以下步骤操作：

### 1. 安装 Cloudflare WARP 官方客户端
以 Debian 12 为例：
```bash
# 导入官方 GPG 密钥
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# 添加 APT 源
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list

# 安装
apt-get update && apt-get install -y cloudflare-warp
```

### 2. 将 WARP 配置为 SOCKS5 本地代理模式
```bash
# 注册客户端
warp-cli --accept-tos registration new

# 设置为 SOCKS5 Proxy 模式并指定端口 40000
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000

# 启动并连接
warp-cli --accept-tos connect

# 检查运行状态 (应显示 Connected / Network: healthy)
warp-cli --accept-tos status

# 验证本地 SOCKS5 代理出口
curl -s -x socks5://127.0.0.1:40000 https://api.ip.sb/geoip
```

### 3. 下载离线规则集 (`.srs`)
为了启动时不依赖外部 HTTP 客户端、实现零延迟解析，推荐将二进制规则集下载至配置目录（例如 `/etc/sing-box/`）：
```bash
CONFIG_DIR="/etc/sing-box"

# Google 域名集合
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs -o "$CONFIG_DIR/geosite-google.srs"

# YouTube 域名集合
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs -o "$CONFIG_DIR/geosite-youtube.srs"

# Google IP CIDR 集合 (用于捕获客户端直连 IP 或 DNS 预解析流量)
curl -sSL https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs -o "$CONFIG_DIR/geoip-google.srs"
```

### 4. 调整 sing-box 配置文件
在 sing-box 的 `config.json` 中配置对应的 `outbounds` 与 `route` 分流：

```json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "default-user",
          "uuid": "00000000-0000-0000-0000-000000000000",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "example.com",
            "server_port": 443
          },
          "private_key": "EXAMPLE_PRIVATE_KEY_HERE",
          "short_id": [
            "01234567"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "rule_set": [
          "geosite-google",
          "geosite-youtube",
          "geoip-google"
        ],
        "outbound": "warp-out"
      }
    ],
    "rule_set": [
      {
        "type": "local",
        "tag": "geosite-google",
        "format": "binary",
        "path": "/etc/sing-box/geosite-google.srs"
      },
      {
        "type": "local",
        "tag": "geosite-youtube",
        "format": "binary",
        "path": "/etc/sing-box/geosite-youtube.srs"
      },
      {
        "type": "local",
        "tag": "geoip-google",
        "format": "binary",
        "path": "/etc/sing-box/geoip-google.srs"
      }
    ]
  }
}
```

### 5. 校验配置并重启
```bash
# 检查语法
sing-box check -c /etc/sing-box/config.json

# 重启服务
systemctl restart sing-box
```

---

## 运维管理

### 规则集自动更新脚本
在规则集存放目录下创建更新脚本 `update-rules.sh`：
```bash
#!/usr/bin/env bash
set -e
CONFIG_DIR="/etc/sing-box"

echo "[*] Updating rule sets in $CONFIG_DIR ..."
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs -o "$CONFIG_DIR/geosite-google.srs"
curl -sSL https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs -o "$CONFIG_DIR/geosite-youtube.srs"
curl -sSL https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs -o "$CONFIG_DIR/geoip-google.srs"

systemctl restart sing-box
echo "[*] Rule sets updated and service restarted successfully."
```
赋予权限：`chmod +x update-rules.sh`。

可在 `crontab -e` 中配置每月或每周执行一次：
```cron
# 每周日凌晨 4 点自动更新规则集
0 4 * * 0 /etc/sing-box/update-rules.sh >/dev/null 2>&1
```

---

## 常见问题排查 (FAQ)

### Q1: WARP 状态显示 `Connecting` 或 `Disconnected`？
- 尝试强制连接：`warp-cli --accept-tos connect`
- 若机房上游网络对 MASQUE/WireGuard 握手协议有丢包，可尝试刷新密钥对：`warp-cli --accept-tos tunnel rotate-keys`
- 重启 WARP 守护进程：`systemctl restart warp-svc`

### Q2: 为什么选择 `type: "local"` 规则集而不是 `remote`？
- 在 sing-box 1.14+ 中，使用 `remote` 规则集需要预设 HTTPClient 与 DNS 依赖，若网络抖动易造成服务启动失败或输出告警；
- 采用本地二进制 `.srs` 规则集完全解耦网络依赖，实现 0 秒极速冷启动，稳定性佳。

### Q3: 如何验证分流是否生效？
1. 在客户端浏览器无痕模式访问 `https://www.google.com`，页面底部应显示为 Cloudflare WARP 出口所在城市（如 San Jose / Los Angeles），而非中国；
2. 访问 `https://gemini.google.com` 正常可用，无地区限制提示；
3. 打开 YouTube 视频并尝试后台播放或画中画功能，一切正常。
