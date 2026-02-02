#!/bin/bash
# Patroni-Stack 一键部署脚本（每台节点执行一次）
# 用法: ./deploy.sh [--no-vip]   # 默认启用 VIP（Keepalived）
# 部署顺序：Node1 先执行，等其 etcd+Patroni 就绪后再在 Node2、Node3 执行

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WITH_VIP=1
[ "${1:-}" = "--no-vip" ] && WITH_VIP=0

echo "========== Patroni-Stack 一键部署 =========="

# 1. 确保 .env 存在
if [ ! -f .env ]; then
  echo ">>> 未找到 .env，从 .env.example 复制（测试 IP: 192.168.0.152/153/154, VIP: 192.168.0.161）"
  cp .env.example .env
  echo ">>> 请按本机修改 .env 中的 NODE_ID、NODE_IP、KEEPALIVED_INTERFACE 后重新执行，或直接继续使用默认测试 IP"
  read -r -p "是否继续使用当前 .env 部署? [y/N] " ans
  case "${ans:-n}" in
    y|Y) ;;
    *) echo "已退出，请编辑 .env 后重新运行 ./deploy.sh"; exit 0 ;;
  esac
fi
set -a
source .env
set +a

# 按节点设置 etcd：Node1 先以单节点集群启动，再 member add 其余节点，避免三节点同时 state=new 相互等待死锁
if [ "$NODE_ID" = "1" ]; then
  export ETCD_INITIAL_CLUSTER_STATE=new
  # Node1 仅以自身为 initial_cluster，可立即启动，不等待其他 etcd
  export ETCD_INITIAL_CLUSTER="etcd1=http://${NODE1_IP}:2380"
else
  export ETCD_INITIAL_CLUSTER_STATE=existing
  # Node2/Node3 的 initial_cluster 必须与“当前集群已有成员”一致，否则报 member count is unequal
  # Node2 启动时集群只有 etcd1+etcd2，Node3 启动时才有 etcd1+etcd2+etcd3，故只列 etcd1..etcd${NODE_ID}
  if [ -z "${ETCD_INITIAL_CLUSTER:-}" ]; then
    ETCD_INITIAL_CLUSTER=""
    for i in $(seq 1 "$NODE_ID"); do
      eval "ip=\$NODE${i}_IP"
      [ -n "$ip" ] && ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER}etcd${i}=http://${ip}:2380,"
    done
    ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER%,}"
  fi
  export ETCD_INITIAL_CLUSTER
fi

# 2. 生成配置
echo ">>> 生成 patroni / haproxy / keepalived 配置"
./scripts/bootstrap.sh
# 校验 patroni.env 与 patroni.yml 中 etcd 地址已写入（Patroni 实际从 YAML 的 etcd3.hosts 读地址，空则报 http://:2379）
if ! grep -q 'PATRONI_ETCD3_HOSTS=..*:2379' patroni/patroni.env 2>/dev/null; then
  echo "错误: patroni/patroni.env 中 PATRONI_ETCD3_HOSTS 为空或异常。请确认本机 .env 已设置 NODE1_IP、NODE2_IP、NODE3_IP 后重新执行 ./scripts/bootstrap.sh"
  echo "当前内容: $(cat patroni/patroni.env 2>/dev/null || echo '文件不存在')"
  exit 1
fi
if ! grep -q 'hosts:.*:2379' patroni/patroni.yml 2>/dev/null; then
  echo "错误: patroni/patroni.yml 中 etcd3.hosts 为空或未替换。Patroni 从该文件读 etcd 地址，空则连到 http://:2379。请在本机执行 ./scripts/bootstrap.sh 重新生成（确保 .env 有 NODE1_IP 等）"
  echo "当前 etcd3 段: $(grep -A2 'etcd3:' patroni/patroni.yml 2>/dev/null || echo '无')"
  exit 1
fi
# 校验 connect_address 为本机物理 IP（非 172.18.x），否则注册到 etcd 会变成 172.18.x
if grep -q 'connect_address:.*172\.18\.' patroni/patroni.yml 2>/dev/null; then
  echo "错误: patroni/patroni.yml 中 connect_address 为 172.18.x，etcd 中会无法跨节点访问。请在本机执行 ./scripts/bootstrap.sh（.env 中 NODE_IP 为本机物理 IP 如 192.168.0.152）"
  echo "当前 connect_address: $(grep connect_address patroni/patroni.yml 2>/dev/null || echo '无')"
  exit 1
fi
expected_ip="${NODE_IP:-}"
if [ -n "$expected_ip" ] && ! grep -q "connect_address: ${expected_ip}:" patroni/patroni.yml 2>/dev/null; then
  echo "错误: patroni/patroni.yml 中 connect_address 与本机 NODE_IP ($expected_ip) 不一致，请在本机执行 ./scripts/bootstrap.sh"
  echo "当前 connect_address: $(grep connect_address patroni/patroni.yml 2>/dev/null || echo '无')"
  exit 1
fi

# 等待远端 etcd 可用的检测（Node2/Node3 用）：先看端口是否开放，再试 /health
wait_for_remote_etcd() {
  local host="$1" max="${2:-180}" n=0
  while [ $n -lt "$max" ]; do
    # 端口已开放即视为可连（etcd 启动中也可能尚未响应 /health）
    if command -v nc >/dev/null 2>&1 && nc -z "$host" 2379 2>/dev/null; then
      return 0
    fi
    if (command -v bash >/dev/null 2>&1 && bash -c "echo >/dev/tcp/$host/2379" 2>/dev/null); then
      return 0
    fi
    if command -v curl >/dev/null 2>&1 && curl -sf --connect-timeout 2 "http://${host}:2379/health" >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 2)); sleep 2; echo "  等待中... ${n}s (检查 ${host}:2379 可连通性，若超时请确认 Node1 已起且防火墙放行 2379/2380)"
  done
  return 1
}

# 3. 若为 Node2/Node3，先等待 Node1 的 etcd 端口可连（再启动本机 etcd）
if [ "$NODE_ID" != "1" ]; then
  echo ">>> 等待 Node1 etcd 可连通（${NODE1_IP}:2379，最多约 3 分钟）..."
  wait_for_remote_etcd "$NODE1_IP" 180 || {
    echo "等待超时。请确认：1) Node1 已先执行 deploy.sh 且 etcd 已 Up；2) 本机到 ${NODE1_IP} 的 2379、2380 端口未被防火墙拦截。"
    exit 1
  }
  echo ">>> Node1 etcd 已可连通"
fi

# 4. 启动 etcd（Node1 单节点先起，Node2/3 用完整列表加入）
echo ">>> 启动 etcd (STATE=$ETCD_INITIAL_CLUSTER_STATE INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER})"
ETCD_INITIAL_CLUSTER="$ETCD_INITIAL_CLUSTER" ETCD_INITIAL_CLUSTER_STATE="$ETCD_INITIAL_CLUSTER_STATE" docker compose up -d etcd
echo ">>> 等待 etcd 健康..."
until docker exec etcd etcdctl --endpoints=http://localhost:2379 endpoint health 2>/dev/null; do
  sleep 2
done
echo ">>> etcd 已健康"

# 4b. Node1：将 etcd2、etcd3（及可选 etcd4～6）加入集群；添加下一成员前需等待前一节点 etcd 已启动（满足 quorum）
if [ "$NODE_ID" = "1" ]; then
  for i in 2 3 4 5 6; do
    eval "ip=\$NODE${i}_IP"
    if [ -z "$ip" ]; then continue; fi
    if docker exec etcd etcdctl --endpoints=http://localhost:2379 member list 2>/dev/null | grep -q "etcd${i}"; then
      echo ">>> etcd${i} 已在集群中，跳过"
      continue
    fi
    # 添加 etcd3 及以后成员前，需等待前一节点 etcd 已启动（etcd 要求多数已启动才能 reconfig）
    if [ "$i" -gt 2 ]; then
      prev=$((i - 1))
      eval "prev_ip=\$NODE${prev}_IP"
      echo ">>> 等待 Node${prev} etcd (${prev_ip}:2379) 启动后再添加 etcd${i}（请先在 Node${prev} 上执行 ./deploy.sh）..."
      wait_for_remote_etcd "$prev_ip" 180 || {
        echo "等待 Node${prev} etcd 超时。请先在 Node${prev} 上执行 ./deploy.sh 直至 etcd 启动，再回到 Node1 重新运行 ./deploy.sh 或执行："
        echo "  docker exec etcd etcdctl --endpoints=http://localhost:2379 member add etcd${i} --peer-urls=http://${ip}:2380"
        exit 1
      }
      echo ">>> 等待 Node${prev} etcd 完全加入集群（约 15 秒）..."
      sleep 15
      echo ">>> 添加 etcd${i}"
    fi
    echo ">>> 将 etcd${i} (${ip}:2380) 加入集群"
    docker exec etcd etcdctl --endpoints=http://localhost:2379 member add etcd${i} --peer-urls=http://${ip}:2380
  done
fi

# 5. 启动 Patroni
echo ">>> 启动 Patroni"
docker compose up -d patroni
if [ "$NODE_ID" = "1" ]; then
  echo ">>> 等待 Patroni 成为 Leader（最多约 90 秒）..."
  LEADER_WAIT=0
  until docker exec patroni patronictl -c /config/patroni.yml list 2>/dev/null | grep -q "Leader"; do
    LEADER_WAIT=$((LEADER_WAIT + 5))
    [ $LEADER_WAIT -ge 90 ] && { echo "等待 Leader 超时"; docker exec patroni patronictl -c /config/patroni.yml list 2>/dev/null || true; exit 1; }
    echo "  等待中... ${LEADER_WAIT}s"
    sleep 5
  done
  echo ">>> Patroni Leader 已就绪"
else
  echo ">>> 等待 Patroni 加入集群（约 15 秒）..."
  sleep 15
fi

# 6. 启动 HAProxy、PGBouncer
echo ">>> 启动 HAProxy、PGBouncer"
docker compose up -d haproxy pgbouncer

# 7. 可选启动 Keepalived（VIP）
if [ "$WITH_VIP" = "1" ]; then
  echo ">>> 启动 Keepalived（VIP: ${VIP}）"
  docker compose --profile with-vip up -d keepalived
else
  echo ">>> 跳过 Keepalived（已使用 --no-vip）"
fi

echo ""
echo "========== 部署完成 =========="
echo "连接信息："
echo "  写（主）:  postgresql://postgres:<密码>@${VIP:-VIP}:5000/postgres  或 @${VIP:-VIP}:6432/postgres"
echo "  读（均衡）: postgresql://postgres:<密码>@${VIP:-VIP}:5001/postgres"
echo "  PGBouncer: postgresql://postgres:<密码>@${VIP:-VIP}:6432/postgres"
echo ""
echo "查看集群: docker exec patroni patronictl -c /config/patroni.yml list"
echo "HAProxy 统计: http://${NODE_IP}:8404/stats"
echo ""
