#!/bin/sh
# Keepalived 健康检查：本机 HAProxy 存活时才持有 VIP
# 使用 nc（Alpine/BusyBox 常见）检测 8404 端口
[ -x /usr/bin/nc ] && /usr/bin/nc -z 127.0.0.1 8404 2>/dev/null && exit 0
[ -x /usr/bin/wget ] && /usr/bin/wget -q -O- http://127.0.0.1:8404/stats >/dev/null 2>&1 && exit 0
[ -x /usr/bin/curl ] && /usr/bin/curl -sf http://127.0.0.1:8404/stats >/dev/null 2>&1 && exit 0
exit 1
