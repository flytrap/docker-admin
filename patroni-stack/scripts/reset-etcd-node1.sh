#!/bin/bash
# Node1 专用：清空 etcd 数据并以单节点重新引导，再 member add 其余节点
# 用于修复 "unhealthy cluster" / "failed to commit proposal: context deadline exceeded"
# （etcd 曾以 3 节点 initial_cluster 启动，数据里仍在等 etcd2/etcd3，无法形成 quorum）
# 用法：仅在 Node1 上执行，完成后可重新运行 ./deploy.sh 或继续启动 Patroni 等

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env"; exit 1; }
source .env

if [ "${NODE_ID:-0}" != "1" ]; then
  echo "此脚本仅应在 Node1 (NODE_ID=1) 上执行。当前 NODE_ID=${NODE_ID:-未设置}"
  exit 1
fi

echo ">>> 停止 etcd"
docker compose stop etcd 2>/dev/null || true

echo ">>> 清空 etcd 数据目录（单节点重新引导）"
rm -rf ./data/etcd/*
mkdir -p ./data/etcd

echo ">>> 以单节点集群启动 etcd (etcd1 only)"
ETCD_INITIAL_CLUSTER="etcd1=http://${NODE1_IP}:2380" \
ETCD_INITIAL_CLUSTER_STATE=new \
docker compose up -d etcd

echo ">>> 等待 etcd 健康..."
until docker exec etcd etcdctl --endpoints=http://localhost:2379 endpoint health 2>/dev/null; do
  sleep 2
done
echo ">>> etcd 已健康（单节点）"

# 等待远端 etcd 端口可连（与 deploy.sh 中逻辑一致）
wait_for_remote_etcd() {
  local host="$1" max="${2:-180}" n=0
  while [ $n -lt "$max" ]; do
    if command -v nc >/dev/null 2>&1 && nc -z "$host" 2379 2>/dev/null; then return 0; fi
    if (command -v bash >/dev/null 2>&1 && bash -c "echo >/dev/tcp/$host/2379" 2>/dev/null); then return 0; fi
    if command -v curl >/dev/null 2>&1 && curl -sf --connect-timeout 2 "http://${host}:2379/health" >/dev/null 2>&1; then return 0; fi
    n=$((n + 2)); sleep 2; echo "  等待中... ${n}s"
  done
  return 1
}

echo ">>> 将 etcd2、etcd3（及可选 etcd4～6）加入集群（添加下一成员前会等待前一节点 etcd 启动）"
for i in 2 3 4 5 6; do
  eval "ip=\$NODE${i}_IP"
  if [ -z "$ip" ]; then continue; fi
  if docker exec etcd etcdctl --endpoints=http://localhost:2379 member list 2>/dev/null | grep -q "etcd${i}"; then
    echo "    etcd${i} 已在集群中，跳过"
    continue
  fi
  if [ "$i" -gt 2 ]; then
    prev=$((i - 1)); eval "prev_ip=\$NODE${prev}_IP"
    echo "    等待 Node${prev} etcd (${prev_ip}:2379) 启动后再添加 etcd${i}..."
    wait_for_remote_etcd "$prev_ip" 180 || { echo "等待 Node${prev} etcd 超时"; exit 1; }
  fi
  echo "    添加 etcd${i} (${ip}:2380)"
  docker exec etcd etcdctl --endpoints=http://localhost:2379 member add etcd${i} --peer-urls=http://${ip}:2380
done

echo ""
echo ">>> Node1 etcd 重置完成。可执行 ./deploy.sh 继续部署，或在 Node2/Node3 上执行 ./deploy.sh。"
