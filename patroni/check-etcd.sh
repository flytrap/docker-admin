#!/bin/bash
# etcd 状态检查脚本

echo "=== 检查 etcd 容器状态 ==="
docker ps | grep etcd || echo "❌ etcd 容器未运行"

echo -e "\n=== 检查 etcd 健康状态 ==="
docker exec -it etcd etcdctl --endpoints=http://localhost:2379 endpoint health 2>/dev/null || echo "❌ etcd 健康检查失败"

echo -e "\n=== 检查 etcd v3 API 数据 ==="
echo "所有 key:"
docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '' --prefix --keys-only" 2>/dev/null || echo "❌ 无法读取数据"

echo -e "\n=== 检查 Patroni 集群数据 (/service/pg-cluster) ==="
docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '/service/pg-cluster' --prefix" 2>/dev/null || echo "❌ 未找到集群数据（可能集群未初始化）"

echo -e "\n=== 检查 etcd 成员 ==="
docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 member list" 2>/dev/null || echo "❌ 无法获取成员列表"

echo -e "\n=== 检查 Patroni 连接 ==="
if docker ps | grep -q patroni1; then
    echo "检查 patroni1 到 etcd 的网络连接:"
    docker exec -it patroni1 ping -c 2 etcd 2>/dev/null || echo "❌ 网络连接失败"
    
    echo -e "\n检查 Patroni 集群状态:"
    docker exec -it patroni1 patronictl -c /config/patroni.yml list 2>/dev/null || echo "❌ 无法获取集群状态"
else
    echo "⚠️  patroni1 容器未运行"
fi
