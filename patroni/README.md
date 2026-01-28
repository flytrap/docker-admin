# Patroni PostgreSQL 高可用集群

基于 Patroni + etcd + HAProxy + PGBouncer 的 PostgreSQL 高可用解决方案。

## 架构说明

- **etcd**: 分布式配置存储，用于 Patroni 的 leader 选举和配置管理
- **Patroni (x3)**: PostgreSQL 高可用管理器，管理 3 个 PostgreSQL 实例
- **HAProxy**: 负载均衡器，提供读写分离
  - 端口 5000: 写入口（仅主节点）
  - 端口 5001: 读入口（所有节点，负载均衡）
  - 端口 8404: HAProxy 统计页面
- **PGBouncer**: 连接池，减少数据库连接开销
  - 端口 6432: 应用连接入口

## 快速开始

### 1. 配置环境变量与密码

- **默认 postgres 密码**：Patroni 配置中为 `flytrap`（见 `patroni/patroni*.yml` 的 `authentication.superuser.password`）。若修改，需同步改连接串和 PGBouncer 的 `POSTGRESQL_PASSWORD`。
- **初始化密码错误**：已通过将 pg_hba 认证方式设为 `scram-sha-256`（与 `password_encryption` 一致）解决；新集群用 `./bootstrap.sh --clean` 初始化即可正常连接。

复制环境变量示例并可选修改密码：

```bash
cp .env.example .env
# 编辑 .env：若改密码，需与 patroni*.yml 中 authentication.superuser.password 一致
```

### 2. 启动服务

**重要**：首次部署或出现「多人抢 leader / uninitialized」时，必须**按顺序**启动，否则会出现多个节点同时 bootstrap、集群状态错乱。

**方式 A：推荐（首次或重置后）**

**一键初始化（推荐）：**

```bash
# 若当前已是 uninitialized，可先只停 Patroni 再执行（无需清数据）
docker-compose stop patroni1 patroni2 patroni3 haproxy pgbouncer
./bootstrap.sh
```

**若 bootstrap 超时（patroni1 一直 uninitialized）：**

常见原因：**残留副本数据**（日志里出现 `starting as a secondary` / `entering standby mode`）或权限问题。此时 Patroni 不会跑 initdb，不会在 etcd 里写入集群状态，必须用 `--clean` 清空 PG 数据后再初始化：

```bash
docker-compose stop patroni1 patroni2 patroni3 haproxy pgbouncer
./bootstrap.sh --clean
```

**完全重置后初始化：**

```bash
# 1) 停掉所有并清空数据（仅首次/重置时需要）
docker-compose down -v
rm -rf ./data/etcd ./data/pg1 ./data/pg2 ./data/pg3
mkdir -p data/etcd data/pg1 data/pg2 data/pg3

# 2) 运行初始化脚本（会先起 etcd → 仅 patroni1 → 等 Leader → 再起 patroni2/3 和 haproxy/pgbouncer）
./bootstrap.sh
```

**手动分步：**

```bash
docker-compose up -d etcd && sleep 10
docker-compose up -d patroni1
# 必须等到 patronictl list 中出现 patroni1 且为 Leader、State=running 后再执行下一步
sleep 60
docker exec -it patroni1 patronictl -c /config/patroni.yml list
docker-compose up -d patroni2 patroni3 && sleep 20
docker-compose up -d haproxy pgbouncer
```

**方式 B：日常重启（集群已正常初始化过）**

```bash
docker-compose up -d
```

编排中已配置：patroni2/patroni3 仅在 patroni1 通过健康检查后才启动，可减少同时 bootstrap 的冲突。

### 3. 验证集群状态

```bash
# 在任意 Patroni 容器内查看集群（推荐从 patroni1 执行）
docker exec -it patroni1 patronictl -c /config/patroni.yml list
# 正常应看到 1 个 Leader、2 个 Replica，且 State 为 running

# 或通过 REST 查看
curl -s http://localhost:8008/cluster | jq .

# HAProxy 统计页面
# 浏览器访问: http://localhost:8404/stats
```

## 连接信息

### 直接连接 PostgreSQL

- **写连接** (主节点): `postgresql://postgres:flytrap@localhost:5000/postgres`
- **读连接** (负载均衡): `postgresql://postgres:flytrap@localhost:5001/postgres`

### 通过 PGBouncer 连接

- **连接字符串**: `postgresql://postgres:flytrap@localhost:6432/postgres`

**默认密码**：配置中为 `flytrap`（见 patroni*.yml 的 `authentication.superuser.password`）。若修改过，请与连接串、PGBouncer 环境变量一致。

### 若报 "password authentication failed for user postgres"

1. **确认密码**：默认 `flytrap`，连接串、PGBouncer 的 `POSTGRESQL_PASSWORD` 需一致。
2. **pg_hba 与加密方式**：`password_encryption` 为 `scram-sha-256` 时，pg_hba 需用 `scram-sha-256`（已改为一致）。
3. **使配置生效**：修改 patroni 配置后需重载集群：
   ```bash
   docker exec -it patroni1 patronictl -c /config/patroni.yml reload pg-cluster --force
   ```
   或重启 Patroni 容器：`docker compose restart patroni1 patroni2 patroni3`
4. **仍失败时**：在主节点重置密码后重试：
   ```bash
   docker exec -it patroni1 psql -U postgres -c "ALTER USER postgres PASSWORD 'flytrap';"
   ```

## 安全建议

⚠️ **重要**: 生产环境请务必修改以下配置：

1. **修改默认密码**
   - 在 `.env` 文件中设置强密码
   - 更新所有 Patroni 配置文件中的密码

2. **网络访问控制**
   - 当前配置限制为内部网络 (172.16.0.0/12, 10.0.0.0/8)
   - 根据实际网络环境调整 `pg_hba` 配置

3. **密码加密方式**
   - 已升级为 `scram-sha-256`（更安全）
   - 首次启动后，需要重新设置用户密码以使用新的加密方式

4. **etcd 安全**
   - 当前为单节点 etcd，生产环境建议使用 3 节点 etcd 集群
   - 启用 etcd 的 TLS 认证

## 监控和维护

### 查看集群状态

```bash
# 方式 1: 使用 patronictl（推荐）
docker exec -it patroni1 patronictl -c /config/patroni.yml list
# 或指定 scope
docker exec -it patroni1 patronictl --scope pg-cluster list

# 方式 2: 使用 REST API
# 查看主节点
curl http://localhost:8008/leader

# 查看所有节点状态
curl http://localhost:8008/cluster

# 查看节点健康状态
curl http://localhost:8008/health
```

### 手动故障转移

```bash
# 切换到指定节点为主节点
curl -X POST http://localhost:8008/switchover
```

### 数据备份

```bash
# 连接到主节点进行备份
docker exec -it patroni1 pg_dumpall -U postgres > backup.sql
```

## 已知限制

1. **etcd 单节点**: 当前 etcd 为单节点，存在单点故障风险
2. **密码管理**: 密码仍硬编码在配置文件中，建议使用密钥管理服务
3. **网络配置**: pg_hba 配置需要根据实际网络环境调整

## 故障排查

### 查看日志

```bash
# 查看所有服务日志
docker-compose logs -f

# 查看特定服务日志
docker-compose logs -f patroni1
docker-compose logs -f haproxy
```

### 常见问题

1. **多人抢 leader / 集群显示 uninitialized、表中无成员**
   - 原因：多个 Patroni 同时启动并同时做 bootstrap，或 patroni2/3 在 patroni1 完成 bootstrap 前就启动了。
   - 处理：执行 `./bootstrap.sh`（会先停 patroni2/3，仅用 patroni1 完成 bootstrap 再启动其余节点）。若仍异常，再做**完全重置**：清空 `./data/etcd` 与 `./data/pg1`～`pg3` 后再次执行 `./bootstrap.sh`。

2. **bootstrap 超时（patroni1 一直 uninitialized）**
   - 原因：多为数据目录权限（容器内 postgres 无法写 `./data/pg1`）或残留/损坏数据。
   - 处理：执行 `./bootstrap.sh --clean`（会清空 data/pg1、pg2、pg3 并放宽目录权限后重新初始化）。超时后脚本会打印 `docker logs patroni1` 最近 80 行，可根据日志中的 Permission denied / initdb 错误进一步排查。

3. **节点无法加入集群**
   - 检查 etcd 是否正常运行
   - 检查网络连接
   - 查看 Patroni 日志

4. **HAProxy 无法检测主节点**
   - 检查 Patroni REST API 是否可访问
   - 验证健康检查配置

5. **连接被拒绝**
   - 检查 pg_hba.conf 配置
   - 验证网络访问权限

6. **patronictl list 报错 "No cluster names were provided"**
   - 必须指定配置文件：`patronictl -c /config/patroni.yml list`
   - 或指定 scope：`patronictl --scope pg-cluster list`

7. **etcd 配置未生效 / patronictl 一直 uninitialized / etcd get 为空**
   - **先跑诊断**：`./debug-dcs.sh`（会列出 etcd 全部 key、容器内 PATRONI_*、配置摘要）
   - 若「所有 key」为空：多半是 Patroni 在用 **etcd v2** 写 key（v2 在 `etcdctl get` v3 里看不到）。已在 docker-compose 里加 `PATRONI_ETCD3_HOSTS: etcd:2379` 强制用 etcd3，请 `./bootstrap.sh --clean` 再试。
   - 若 etcd 里有 key 但路径不是 `/service/pg-cluster`：把 `./debug-dcs.sh` 里看到的路径贴出来，或把 config 的 namespace/scope 改成与之一致。
   - 检查 etcd 容器是否正常运行：`docker ps | grep etcd`
   - 检查 etcd 健康状态：`docker exec -it etcd etcdctl --endpoints=http://localhost:2379 endpoint health`
   - **查看 etcd v3 数据**（Patroni 使用 etcd3 API）：
     ```bash
     # 查看所有 key（v3 API）
     docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '' --prefix --keys-only"
     
     # 查看 Patroni 集群数据
     docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '/service/pg-cluster' --prefix"
     
     # 查看所有数据（包含值）
     docker exec -it etcd sh -c "ETCDCTL_API=3 etcdctl --endpoints=http://localhost:2379 get '' --prefix"
     ```
   - 检查 Patroni 能否连接 etcd：查看 Patroni 日志 `docker logs patroni1 | grep -i etcd`
   - 确认 etcd 和 Patroni 在同一网络：`docker network inspect patroni_pg-net`
   - **如果 etcd 数据为空**：
     - 确认集群已初始化：`docker exec -it patroni1 patronictl -c /config/patroni.yml list`
     - 如果显示 "uninitialized"，需要按「首次部署」步骤重新初始化
     - 检查 Patroni 日志是否有连接 etcd 的错误

## 性能调优

配置文件已包含基本的性能参数，可根据实际负载调整：

- `shared_buffers`: 共享缓冲区大小
- `effective_cache_size`: 有效缓存大小
- `max_connections`: 最大连接数
- `work_mem`: 工作内存

建议根据服务器内存和负载情况调整这些参数。
