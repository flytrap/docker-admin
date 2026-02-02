#!/bin/bash
# 根据 .env 生成 patroni/patroni.yml（含 NODE_ID、NODE_IP、etcd 地址、密码等）
# 支持 3～6 节点：设置 NODE4_IP、NODE5_IP、NODE6_IP 即可纳入 etcd 与集群

set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env，请从 .env.example 复制并填写"; exit 1; }
source .env

# 去除可能的 Windows 换行符 \r，避免 PATRONI_ETCD3_HOSTS 解析异常（No host specified）
for v in NODE_ID NODE_IP NODE1_IP NODE2_IP NODE3_IP NODE4_IP NODE5_IP NODE6_IP; do
  eval "val=\${$v:-}"
  [ -n "$val" ] && eval "$v=\${val//\$'\r'/}"
done

# 构建 etcd 主机列表（NODE1_IP 必填，NODE4_IP 等可选）
[ -n "${NODE1_IP:-}" ] || { echo "错误: .env 中未设置 NODE1_IP，Patroni 需要 etcd 地址。请确保每台节点的 .env 都包含 NODE1_IP、NODE2_IP、NODE3_IP（与 .env.example 一致）。"; exit 1; }
ETCD_HOSTS="${NODE1_IP}:2379"
for i in 2 3 4 5 6; do
  eval "ip=\$NODE${i}_IP"
  [ -n "$ip" ] && ETCD_HOSTS="${ETCD_HOSTS},${ip}:2379"
done
# 避免生成空 host（会导致 Patroni 报 No host specified）
case "$ETCD_HOSTS" in
  :*|,*) echo "错误: ETCD_HOSTS 异常（$ETCD_HOSTS），请检查 .env 中 NODE1_IP 等是否填写正确"; exit 1 ;;
esac
export ETCD_HOSTS

export NODE_ID
export NODE_IP
export POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-flytrap}"
export POSTGRES_REPLICATION_PASSWORD="${POSTGRES_REPLICATION_PASSWORD:-replicator}"

mkdir -p patroni
envsubst '$NODE_ID $NODE_IP $ETCD_HOSTS $POSTGRES_SUPERUSER_PASSWORD $POSTGRES_REPLICATION_PASSWORD' \
  < patroni/patroni.yml.tpl > patroni/patroni.yml
# 生成 patroni.env 供容器启动时 source；含 NODE_IP 以便 YAML 中若有 ${NODE_IP} 运行时替换也能得到正确值
{
  printf 'NODE_IP=%s\nPATRONI_ETCD3_HOSTS=%s\nPATRONI_POSTGRESQL_CONNECT_ADDRESS=%s:5432\nPATRONI_RESTAPI_CONNECT_ADDRESS=%s:8008\n' \
    "$NODE_IP" "$ETCD_HOSTS" "$NODE_IP" "$NODE_IP"
} | tr -d '\r' > patroni/patroni.env
# 校验生成的 patroni.yml 中 connect_address 已是字面量 IP（非 ${NODE_IP}），避免 Patroni 运行时替换为空得到 172.18.x
if grep -q 'connect_address:.*\$' patroni/patroni.yml 2>/dev/null; then
  echo "错误: patroni/patroni.yml 中 connect_address 仍含变量，请确认 .env 中 NODE_IP 已设置后重新执行"
  exit 1
fi
# 校验 data_dir 为 /home/postgres/pgdata/data（与 docker-compose 挂载一致），避免从节点报 postmaster.opts / wrong ownership
if ! grep -q 'data_dir: /home/postgres/pgdata/data' patroni/patroni.yml 2>/dev/null; then
  echo "错误: patroni/patroni.yml 中 data_dir 应为 /home/postgres/pgdata/data，请使用当前 patroni/patroni.yml.tpl 后重新执行"
  exit 1
fi
echo "已生成 patroni/patroni.yml 与 patroni/patroni.env (name=patroni${NODE_ID} connect_address=${NODE_IP} etcd_hosts=${ETCD_HOSTS})"
