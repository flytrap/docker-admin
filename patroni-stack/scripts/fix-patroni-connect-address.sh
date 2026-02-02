#!/bin/bash
# 强制 Patroni 用本机物理 IP 重新注册到 etcd（解决 etcd 里 conn_url/api_url 仍是 172.18.x）
# 每台节点执行前请确认本机 .env 中 NODE_IP 为本机物理 IP（如 192.168.0.152/153/154）

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env"; exit 1; }
source .env

case "${NODE_IP:-}" in
  "") echo "错误: .env 中 NODE_IP 未设置"; exit 1 ;;
  172.*) echo "错误: NODE_IP 不能是 172.x（Docker 网段），请改为本机物理 IP"; exit 1 ;;
  *) ;;
esac

echo "本机 NODE_IP=$NODE_IP，将用该地址注册到 etcd"
echo ">>> 强制重建 patroni 容器以应用环境变量..."
docker compose up -d --force-recreate patroni
echo ">>> 等待 Patroni 就绪并写回 etcd（约 10～15 秒）..."
sleep 12
docker exec patroni env | grep -E 'PATRONI_POSTGRESQL_CONNECT_ADDRESS|PATRONI_RESTAPI_CONNECT_ADDRESS' || true
echo ">>> 完成。"
echo ">>> 确认 etcd 中 conn_url 已为物理 IP："
echo "    docker exec -it etcd etcdctl --endpoints=${NODE1_IP}:2379,${NODE2_IP}:2379,${NODE3_IP}:2379 get /service/pg-cluster/members/ --prefix"
echo ">>> 若仍为 172.18.x：在容器内执行 cat /config/patroni.yml | grep connect_address，若为 172.x 说明宿主机 patroni.yml 生成时 NODE_IP 错误，请在本机执行 ./scripts/gen-patroni.sh 后再次运行本脚本。"
