#!/bin/bash
# 根据 .env 生成 haproxy/haproxy.cfg（支持 3～6 节点：NODE4_IP 等可选）

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env"; exit 1; }
source .env

mkdir -p haproxy
BACKEND_LINES=""
for i in 1 2 3 4 5 6; do
  eval "ip=\$NODE${i}_IP"
  [ -n "$ip" ] && BACKEND_LINES="${BACKEND_LINES}    server pg${i} ${ip}:5432 check port 8008
"
done
[ -z "$BACKEND_LINES" ] && { echo "至少需设置 NODE1_IP"; exit 1; }

TMP_SERVERS=$(mktemp)
printf '%s' "$BACKEND_LINES" > "$TMP_SERVERS"
sed -e '/__BACKEND_SERVERS__/r '"$TMP_SERVERS" -e '/__BACKEND_SERVERS__/d' \
  haproxy/haproxy.cfg.tpl > haproxy/haproxy.cfg
rm -f "$TMP_SERVERS"

echo "已生成 haproxy/haproxy.cfg"
grep -E "server pg[0-9]" haproxy/haproxy.cfg