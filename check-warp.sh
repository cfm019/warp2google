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
import re

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
    print("                 -> 可在服务器上执行: warp-cli disconnect && warp-cli connect 刷新 IP")
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
