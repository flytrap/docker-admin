#!/bin/bash
# 清除 etcd 中 Patroni 成员键（conn_url/api_url 为 172.18.x 时无法跨节点访问）
# 清除后需在每台节点依次执行：bootstrap + force-recreate patroni，使其用 NODE_IP 重新注册
# 用法：在任意一台能连到 etcd 的节点执行一次即可

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env"; exit 1; }
source .env

ENDPOINTS="${NODE1_IP}:2379,${NODE2_IP}:2379,${NODE3_IP}:2379"
echo ">>> 清除 etcd 中的 Patroni 成员键（endpoints=$ENDPOINTS）"
for m in patroni1 patroni2 patroni3; do
  if docker exec etcd etcdctl --endpoints="$ENDPOINTS" get "/service/pg-cluster/members/$m" >/dev/null 2>&1; then
    docker exec etcd etcdctl --endpoints="$ENDPOINTS" del "/service/pg-cluster/members/$m"
    echo "    已删除 /service/pg-cluster/members/$m"
  else
    echo "    跳过 $m（不存在）"
  fi
done
echo ""
echo ">>> 完成。请在每台节点依次执行（先 Node1，再 Node2，再 Node3）："
echo "    ./scripts/bootstrap.sh   # 确保 patroni.env / patroni.yml 为本机 NODE_IP"
echo "    docker compose up -d --force-recreate patroni"
echo "  等约 15 秒后检查："
echo "    docker exec etcd etcdctl --endpoints=$ENDPOINTS get /service/pg-cluster/members/ --prefix"
echo "  conn_url / api_url 应为 192.168.0.152、192.168.0.153、192.168.0.154，不再是 172.18.x"
