#!/bin/bash
# Patroni 集群首次初始化脚本
# 确保只有 patroni1 先完成 bootstrap，再启动 patroni2/3
# 用法: ./bootstrap.sh [--clean]
#   --clean  清空 data/pg1、pg2、pg3 后再初始化（必须用于：残留副本数据、权限问题、或 patronictl 一直 uninitialized）

set -e
cd "$(dirname "$0")"

CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

if [ "$CLEAN" -eq 0 ]; then
  echo "提示: 未使用 --clean。若 data/pg1 内有旧副本数据，bootstrap 会失败且 patronictl 会一直显示 uninitialized。"
  echo "      建议先执行: ./bootstrap.sh --clean"
  echo ""
fi

echo "=== 1. 停止所有 Patroni 节点（保留 etcd）==="
docker compose stop patroni1 patroni2 patroni3 haproxy pgbouncer 2>/dev/null || true

if [ "$CLEAN" -eq 1 ]; then
  echo "=== 1b. 清空数据目录（--clean）==="
  docker compose stop patroni1 patroni2 patroni3 etcd 2>/dev/null || true
  rm -rf ./data/etcd ./data/pg1 ./data/pg2 ./data/pg3
  mkdir -p data/etcd data/pg1 data/pg2 data/pg3
  # 使数据目录可被容器内 postgres 用户写入（常见 uid 26 或 999）
  chmod 777 ./data/etcd ./data/pg1 ./data/pg2 ./data/pg3 2>/dev/null || true
fi

echo "=== 2. 确保 etcd 运行 ==="
docker compose up -d etcd
echo "等待 etcd 就绪..."
sleep 10
docker exec etcd etcdctl --endpoints=http://localhost:2379 endpoint health || { echo "etcd 未就绪"; exit 1; }

echo "=== 3. 仅启动 patroni1，等待其完成 bootstrap ==="
docker compose up -d patroni1

echo "等待 patroni1 完成 bootstrap（最多 120 秒）..."
for i in $(seq 1 24); do
  sleep 5
  OUT=$(docker exec patroni1 patronictl -c /config/patroni.yml list 2>/dev/null || true)
  if echo "$OUT" | grep -q "patroni1" && echo "$OUT" | grep -q "Leader" && echo "$OUT" | grep -q "running"; then
    echo "patroni1 已成为 Leader，bootstrap 完成。"
    break
  fi
  if echo "$OUT" | grep -q "patroni1"; then
    echo "patroni1 已出现在集群中，继续等待..."
  else
    echo "等待中... ($((i*5))s)"
  fi
  if [ "$i" -eq 24 ]; then
    echo "超时。当前状态:"
    docker exec patroni1 patronictl -c /config/patroni.yml list 2>/dev/null || true
    echo ""
    echo "=== patroni1 最近日志（排查 initdb/权限 错误）==="
    LOGS=$(docker logs patroni1 2>&1 | tail -80)
    echo "$LOGS"
    echo ""
    if echo "$LOGS" | grep -q "starting as a secondary"; then
      echo ">>> 检测到残留副本数据（未使用 --clean）。必须清空数据后重新初始化，请执行："
      echo "    ./bootstrap.sh --clean"
    else
      echo "若为权限错误，请执行: ./bootstrap.sh --clean"
      echo "若为残留副本/旧数据，请执行: ./bootstrap.sh --clean"
    fi
    exit 1
  fi
done

echo "=== 4. 启动 patroni2、patroni3 ==="
docker compose up -d patroni2 patroni3
sleep 15

echo "=== 5. 启动 haproxy、pgbouncer ==="
docker compose up -d haproxy pgbouncer

echo "=== 6. 集群状态 ==="
docker exec patroni1 patronictl -c /config/patroni.yml list

# 修改默认密码
docker exec -it patroni1 psql -U postgres -c "ALTER USER postgres PASSWORD 'flytrap';"

echo ""
echo "初始化完成。可用: docker exec -it patroni1 patronictl -c /config/patroni.yml list 查看状态。"
