#!/bin/bash
# 当前节点初始化：生成 patroni.yml、keepalived.conf 并可选启动服务
# 每台机器部署前执行一次

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "请先复制 .env.example 为 .env 并按本机填写 NODE_ID、NODE_IP、VIP 等"; exit 1; }

echo "=== 生成 patroni/patroni.yml ==="
./scripts/gen-patroni.sh
echo "=== 生成 haproxy/haproxy.cfg ==="
./scripts/gen-haproxy.sh
echo "=== 生成 keepalived/keepalived.conf ==="
./scripts/gen-keepalived.sh
echo "=== 创建数据目录 ==="
mkdir -p data/etcd data/pg
chmod 777 data/etcd data/pg 2>/dev/null || true
echo "=== 完成。启动方式："
echo "  不含 VIP: docker compose up -d"
echo "  含 VIP:   docker compose --profile with-vip up -d"
echo ""
