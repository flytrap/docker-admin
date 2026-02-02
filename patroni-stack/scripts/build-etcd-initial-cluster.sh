#!/bin/bash
# 输出当前 .env 对应的 ETCD_INITIAL_CLUSTER 值（扩展节点时，在新节点 .env 中设置此变量）
# 用法: ./scripts/build-etcd-initial-cluster.sh  或  source .env; ./scripts/build-etcd-initial-cluster.sh

set -e
cd "$(dirname "$0")/.."
[ -f .env ] && source .env 2>/dev/null || true

list=""
for i in 1 2 3 4 5 6; do
  eval "ip=\$NODE${i}_IP"
  [ -n "$ip" ] && list="${list}etcd${i}=http://${ip}:2380,"
done
list="${list%,}"
[ -z "$list" ] && { echo "请设置 NODE1_IP 等"; exit 1; }
echo "ETCD_INITIAL_CLUSTER=${list}"
echo "# 将上一行加入新节点的 .env，并设置 ETCD_INITIAL_CLUSTER_STATE=existing"
