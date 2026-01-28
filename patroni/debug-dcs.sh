#!/bin/bash
# 诊断 Patroni 与 etcd/DCS 的路径与连接

echo "=== 1. etcd 中所有 key（v3 API）==="
docker exec etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '' --prefix --keys-only" 2>/dev/null || echo "失败"
echo ""

echo "=== 2. 尝试不同 prefix（无前导斜杠）==="
docker exec etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get 'service' --prefix --keys-only" 2>/dev/null || echo "失败"
echo ""

echo "=== 3. patroni1 容器内 PATRONI_* 环境变量 ==="
docker exec patroni1 env 2>/dev/null | grep -E '^PATRONI_' || echo "无或容器未运行"
echo ""

echo "=== 4. patroni1 挂载的配置（namespace/scope/etcd3）==="
docker exec patroni1 sh -c "grep -E '^(scope|namespace|  hosts:)' /config/patroni.yml 2>/dev/null || cat /config/patroni.yml | head -15"
echo ""

echo "=== 5. 若镜像设置了 PATRONI_CONFIGURATION，会覆盖配置文件 ==="
docker exec patroni1 sh -c 'echo "PATRONI_CONFIGURATION length: ${#PATRONI_CONFIGURATION}"' 2>/dev/null
