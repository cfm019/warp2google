#!/usr/bin/env bash
# ==============================================================================
# Cloudflare WARP 出口 IP 与属地分流检测脚本
# 用于检测本地 WARP SOCKS5 (127.0.0.1:40000) 及 Google / YouTube 送中状态
# ==============================================================================
set -e

WARP_PORT="${1:-40000}"

python3 - << PYEOF
import urllib.request
import urllib.parse
import json
import base64
import subprocess
import sys

warp_port = int("$WARP_PORT")
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

def check_youtube_region(proxy=None):
    cmd = ["curl", "-sI", "--max-time", "8"]
    if proxy:
        cmd.extend(["-x", proxy])
    cmd.append("https://www.youtube.com")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        for line in res.stdout.splitlines():
            if "VISITOR_PRIVACY_METADATA=" in line:
                token = line.split("VISITOR_PRIVACY_METADATA=")[1].split(";")[0].strip()
                token = urllib.parse.unquote(token)
                raw = base64.b64decode(token)
                if len(raw) >= 4 and raw[0] == 0x0a:
                    cc_len = raw[1]
                    return raw[2:2+cc_len].decode("ascii", errors="ignore").upper()
    except Exception:
        pass
    return "UNKNOWN"

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

# 原生 IP 对比
native_yt = check_youtube_region(None)
native_v4 = fetch_ip(None, 4)

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
    print("                 -> 可在服务器上执行: warp-cli disconnect && warp-cli connect 刷新 IP")
elif yt_region and yt_region != "UNKNOWN":
    print(f" YouTube 判定区 : \033[32m{yt_region} (正常，解除送中，支持 YouTube Premium)\033[0m")
else:
    print(f" YouTube 判定区 : \033[33mUNKNOWN (检测超时或响应解析失败)\033[0m")

print("-" * 62)
native_yt_desc = f"{native_yt} (已送中)" if native_yt == "CN" else (native_yt if native_yt and native_yt != "UNKNOWN" else "未知")
print(f" VPS 原生出口 IP: {native_v4 if native_v4 else '未知'} (YouTube 判定: {native_yt_desc})")
print("="*62 + "\n")
PYEOF
