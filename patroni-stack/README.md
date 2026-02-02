# Patroni-Stack：3 节点高可用 PostgreSQL 集群

在 **3 台物理机** 上，每台通过 **docker-compose** 部署一套：**Patroni + etcd + HAProxy + PGBouncer + Keepalived**，组成一个高可用 PostgreSQL 集群，并通过 **VIP 自动漂移** 对外提供单一入口。

## 架构概览

```
                    客户端
                       │
                       ▼
              ┌────────────────┐
              │  VIP (漂移)     │  写:5432/5000/6432  读:5001
              └────────┬───────┘
                       │
     ┌─────────────────┼─────────────────┐
     ▼                 ▼                 ▼
┌─────────┐       ┌─────────┐       ┌─────────┐
│ Node 1  │       │ Node 2  │       │ Node 3  │
│ etcd1   │       │ etcd2   │       │ etcd3   │  ← etcd 3 节点集群
│ patroni1│       │ patroni2│       │ patroni3│  ← Patroni PG 集群（1 主 2 从）
│ haproxy │       │ haproxy │       │ haproxy │  ← 写/读分离
│ pgbouncer       │ pgbouncer       │ pgbouncer
│ keepalived      │ keepalived      │ keepalived  ← VIP 由当前 MASTER 持有
└─────────┘       └─────────┘       └─────────┘
```

- **etcd**：3 节点集群，Patroni 的 DCS；使用 **端口映射**（2379、2380），通过 NODE_IP 对外宣告。
- **Patroni**：每机 1 个 PostgreSQL 实例，自动主从复制与故障转移；使用 **端口映射**（5432、8008），通过环境变量 `PATRONI_*_CONNECT_ADDRESS` 设为 NODE_IP，注册到 etcd 的地址为宿主机 IP，副本可跨节点连接。
- **HAProxy**：写入口（仅主）5000、读入口（负载均衡）5001、统计 8404。
- **PGBouncer**：连接池，端口 6432。
- **Keepalived**：VRRP 管理 VIP，仅当前“主”节点持有 VIP；该节点故障时 VIP 漂移到其他节点，实现入口高可用。

## 目录结构

```
patroni-stack/
├── .env.example          # 环境变量示例（默认测试 IP: 152/153/154, VIP: 161）
├── deploy.sh             # 一键部署脚本（每台执行一次，Node1 先执行）
├── docker-compose.yaml   # 单节点编排（etcd + patroni + haproxy + pgbouncer + keepalived）
├── patroni/
│   ├── patroni.yml.tpl   # Patroni 配置模板
│   └── patroni.yml       # 由 scripts/gen-patroni.sh 生成
├── haproxy/
│   ├── haproxy.cfg.tpl   # HAProxy 配置模板（后端为三节点 IP）
│   └── haproxy.cfg       # 由 scripts/gen-haproxy.sh 生成
├── keepalived/
│   ├── keepalived.conf.tpl   # Keepalived 配置模板
│   ├── keepalived.conf       # 由 scripts/gen-keepalived.sh 生成
│   └── check_haproxy.sh      # VIP 持有条件：本机 HAProxy 存活
├── scripts/
│   ├── bootstrap.sh      # 本机初始化（生成配置 + 建目录）
│   ├── gen-patroni.sh    # 生成 patroni/patroni.yml
│   ├── gen-haproxy.sh    # 生成 haproxy/haproxy.cfg（支持 3～6 节点）
│   ├── gen-keepalived.sh # 生成 keepalived/keepalived.conf（支持 NODE_ID 1～6）
│   ├── build-etcd-initial-cluster.sh # 输出 ETCD_INITIAL_CLUSTER（扩展节点时在新节点 .env 使用）
│   └── reset-etcd-node1.sh          # Node1 专用：etcd 单节点重新引导（修复 unhealthy cluster）
└── data/                 # 本机数据（etcd、PostgreSQL）
```

## 部署步骤

### 一键部署（推荐）

默认测试 IP：节点 192.168.0.152 / 192.168.0.153 / 192.168.0.154，VIP 192.168.0.161。Keepalived 使用镜像 `osixia/keepalived:stable`。

在 **每台机器** 上克隆并执行（**必须先 Node1，再 Node2、Node3**）：

```bash
git clone <repo> patroni-stack && cd patroni-stack
# 按本机修改 .env 中的 NODE_ID、NODE_IP、KEEPALIVED_INTERFACE（不修改则使用 .env.example 的测试 IP）
./deploy.sh
```

- 首次运行若无 `.env` 会从 `.env.example` 复制（含上述测试 IP），可按提示继续或编辑后重跑。
- **etcd 启动顺序（避免死锁）**：Node1 先以 **单节点集群** 启动 etcd，然后 `member add etcd2`；添加 etcd3 前需 **多数成员已启动**，故 Node1 会等待 Node2 的 etcd（192.168.0.153:2379）可连通后再 `member add etcd3`。因此：**先启动 Node1 的 deploy，当 Node1 打印「等待 Node2 etcd…」时，在 Node2 上执行 ./deploy.sh**；Node1 检测到 Node2 etcd 后会自动添加 etcd3 并继续。
- `deploy.sh` 会：生成配置 → Node1 单节点 etcd → member add etcd2 → 等待 Node2 etcd 可连 → member add etcd3（及可选 etcd4～6）→ Patroni（Node1 会等 Leader）→ HAProxy、PGBouncer、Keepalived（VIP）。
- 不启用 VIP 时：`./deploy.sh --no-vip`。

### 手动部署

#### 1. 准备三台物理机

- 每台可被另外两台通过 IP 访问（防火墙放行：2379、2380、5432、8008、5000、5001、8404、6432，以及 VRRP 组播/单播）。
- 每台安装 Docker、Docker Compose，并拉取/构建所需镜像（见下文）。

#### 2. 克隆项目并配置本机 .env

在 **每台机器** 上：

```bash
git clone <repo> patroni-stack && cd patroni-stack
cp .env.example .env
```

编辑 **.env**，**三台机器的 NODE1_IP / NODE2_IP / NODE3_IP / VIP 必须完全一致**，仅下列项按本机填写。**每台节点都必须填写 NODE1_IP、NODE2_IP、NODE3_IP**（用于生成 `patroni/patroni.env` 中的 etcd 地址），否则 Patroni 会报 "No host specified"。

| 变量 | 说明 | Node1 示例 | Node2 | Node3 |
|------|------|------------|-------|-------|
| NODE_ID | 节点编号 | 1 | 2 | 3 |
| NODE_IP | 本机 IP | 192.168.0.152 | 192.168.0.153 | 192.168.0.154 |
| NODE1_IP / NODE2_IP / NODE3_IP | 三节点 IP（三台一致） | 152/153/154 | 同左 | 同左 |
| VIP | 虚拟 IP（三台一致） | 192.168.0.161 | 同左 | 同左 |
| KEEPALIVED_INTERFACE | VRRP 网卡名 | eth0 | eth0 | eth0 |
| ETCD_INITIAL_CLUSTER_STATE | 首启 etcd 的节点填 new，其余填 existing | new | existing | existing |

可选：修改 `POSTGRES_SUPERUSER_PASSWORD`、`POSTGRESQL_PASSWORD`、`KEEPALIVED_AUTH_PASS` 等（三台保持一致）。

#### 3. 本机初始化（每台执行一次）

在 **每台机器** 上：

```bash
./scripts/bootstrap.sh
```

会生成 `patroni/patroni.yml`、`haproxy/haproxy.cfg`、`keepalived/keepalived.conf` 并创建 `data/etcd`、`data/pg`。

### 4. 启动 etcd 集群（建议顺序）

- **先启动一台**（例如 Node1，且 .env 中 `ETCD_INITIAL_CLUSTER_STATE=new`）：

  ```bash
  docker compose up -d etcd
  ```

  等待 etcd 就绪（可 `docker exec etcd etcdctl endpoint health`）。

- **再启动另外两台**（.env 中 `ETCD_INITIAL_CLUSTER_STATE=existing`）：

  ```bash
  docker compose up -d etcd
  ```

三台 etcd 组成集群后，再启动 Patroni。

### 5. 启动 Patroni（建议先起一台做 primary）

- 在 **一台** 上先起 Patroni，等待其成为 Leader（可 `docker exec patroni patronictl -c /config/patroni.yml list`）。
- 再在 **其余两台** 上：

  ```bash
  docker compose up -d patroni
  ```

### 6. 启动 HAProxy、PGBouncer

三台 Patroni 都就绪后，在 **每台** 上：

```bash
docker compose up -d haproxy pgbouncer
```

### 7. 启用 VIP（Keepalived）

在 **每台** 上：

```bash
docker compose --profile with-vip up -d keepalived
```

默认 Node1 为 MASTER（优先级最高），持有 VIP；Node2/3 为 BACKUP。当持有 VIP 的节点或本机 HAProxy 不可用时，VIP 会漂移到其他节点。

### 一键启动（集群已初始化后）

若 etcd、Patroni 已按上述顺序初始化过，日常可在每台执行：

```bash
docker compose up -d
# 需要 VIP 时
docker compose --profile with-vip up -d
```

## 连接方式

- **写（主库）**：`postgresql://postgres:<密码>@<VIP>:5000/postgres` 或 `@<VIP>:6432/postgres`（经 PGBouncer）
- **读（负载均衡）**：`postgresql://postgres:<密码>@<VIP>:5001/postgres`
- **经 PGBouncer（推荐应用使用）**：`postgresql://postgres:<密码>@<VIP>:6432/postgres`

将应用连接串中的主机改为 **VIP**，即可在单节点故障时自动切到其他节点，实现高可用。

## VIP 自动漂移说明

- Keepalived 使用 VRRP：同一 `virtual_router_id` 下，**priority 最高** 且 **本机 check 脚本通过** 的节点持有 VIP。
- 默认 Node1 为 MASTER（priority 103），Node2/3 为 BACKUP（102/101）。若 Node1 宕机或本机 HAProxy 不可用，`check_haproxy.sh` 失败会导致 priority 降低，VIP 漂到 Node2 或 Node3。
- 漂移后，客户端仍连接 **VIP:5000 / VIP:6432**，由新节点的 HAProxy/PGBouncer 提供服务，无需改应用配置。

## 验证与运维

- 查看 Patroni 集群：`docker exec patroni patronictl -c /config/patroni.yml list`
- 查看当前主节点：`curl -s http://<任意节点 IP>:8008/leader`
- HAProxy 统计：`http://<节点 IP 或 VIP>:8404/stats`
- 验证 VIP：在任一节点 `ip addr` 或 `ping <VIP>`，应在当前 MASTER 节点上看到 VIP。

### etcd 健康检查（Node1 上 curl 本机 2379 失败时）

- **Node1 本机**：`curl -s http://192.168.0.152:2379/health` 失败时，可先确认 etcd 是否在容器内正常：
  ```bash
  docker exec etcd etcdctl --endpoints=http://localhost:2379 endpoint health
  ```
  若容器内正常，再试本机回环：`curl -s http://127.0.0.1:2379/health`。若 127.0.0.1 可通而 192.168.0.152 不通，多为端口未绑定到外网或防火墙拦截；compose 已使用 `0.0.0.0:2379:2379`，重启 etcd 后一般可通。
- **Patroni 镜像内 etcd**：部分版本不提供 HTTP `/health`，Node2/Node3 的等待脚本会优先用 **TCP 端口检测**（`nc -z <Node1_IP> 2379`），只要 2379 端口可连即可继续部署，不依赖 `/health`。
- **跨节点连通**：在 Node2/Node3 上执行 `nc -zv 192.168.0.152 2379`、`nc -zv 192.168.0.152 2380`，确认防火墙已放行。
- **Node2/Node3 报错 "failed to open stdout fifo ... no such file or directory"**：多为 Docker/containerd 运行时临时问题。可先 `docker compose down`，再 `docker compose up -d` 重试；必要时重启 Docker 服务。
- **Node2 报错 "member count is unequal"**：etcd 要求启动时的 `initial_cluster` 与当前集群已有成员数一致。Node2 启动时集群只有 etcd1+etcd2，故 Node2 的 `ETCD_INITIAL_CLUSTER` 只能含 etcd1 和 etcd2；deploy 脚本已按 `etcd1..etcd${NODE_ID}` 自动生成，无需在 .env 中手写完整 3 节点列表。若曾手写过完整列表，删掉 .env 中的 `ETCD_INITIAL_CLUSTER` 后重跑 deploy 即可。
- **etcd 里成员 conn_url/api_url 全是 172.18.x、副本 pg_basebackup connection refused**：Patroni 在容器内会把自己的地址解析成 Docker 网桥 IP（如 172.18.0.3）。compose 通过环境变量 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`、`PATRONI_RESTAPI_CONNECT_ADDRESS` 强制使用 .env 中的 `NODE_IP`；若未传入或为空，Patroni 会用容器 IP 注册。

  **排查（在报错节点上执行）：**
  1. 看容器内是否拿到正确地址：`docker exec patroni env | grep -E 'PATRONI_POSTGRESQL_CONNECT_ADDRESS|PATRONI_RESTAPI_CONNECT_ADDRESS'`  
     应为 `PATRONI_POSTGRESQL_CONNECT_ADDRESS=本机物理IP:5432`（如 192.168.0.152:5432）。若为空或为 172.18.x，说明 compose 未从 .env 展开 NODE_IP。
  2. **connect_address 来自 patroni.env**（由 `./scripts/bootstrap.sh` 按本机 NODE_IP 生成）。compose 不再在 environment 里传 PATRONI_*_CONNECT_ADDRESS，避免从错误目录起 compose 时传入空值覆盖 patroni.env 导致注册成 172.18.x。**每台节点必须先在本机执行** `./scripts/bootstrap.sh`（本机 .env 中 NODE_IP 为本机物理 IP），再 `docker compose up -d`。
  3. 确认本机 .env 中 `NODE_IP=` 为本机物理 IP；`cat patroni/patroni.env` 中应有 `PATRONI_POSTGRESQL_CONNECT_ADDRESS=本机IP:5432`；`grep -A2 etcd3 patroni/patroni.yml` 中 `hosts:` 应为三节点 IP:2379，`connect_address` 应为本机 NODE_IP。

  **修复（etcd 里已是 172.18.x 时需先清成员再重注册）：**
  1. 在**任意一台**能连 etcd 的节点执行，清除 etcd 中错误的成员键：
     ```bash
     ./scripts/clear-etcd-patroni-members.sh
     ```
  2. 在**每台节点**依次执行（先 Node1，再 Node2，再 Node3），确保本机 .env 中 `NODE_IP=` 为本机物理 IP：
     ```bash
     ./scripts/bootstrap.sh
     docker compose up -d --force-recreate patroni
     ```
  3. 等约 15 秒后检查：`docker exec etcd etcdctl --endpoints=192.168.0.152:2379,192.168.0.153:2379,192.168.0.154:2379 get /service/pg-cluster/members/ --prefix`，conn_url/api_url 应为 192.168.0.152、192.168.0.153、192.168.0.154。
  4. 若未先清成员，也可在每台执行 `./scripts/fix-patroni-connect-address.sh`（先 Leader 所在节点，再其他），但若 Patroni 不覆盖旧 key，需先执行步骤 1。
- **Patroni 报错 "http://:2379"、"No host specified"**：说明容器内 `PATRONI_ETCD3_HOSTS` 为空或格式错误。**每台节点的 .env 必须包含 NODE1_IP、NODE2_IP、NODE3_IP**（与 .env.example 一致，三台机器的这三项完全一致），否则 `gen-patroni.sh` 会生成空的 etcd 列表。处理：1）确认本机 .env 有 `NODE1_IP=192.168.0.152`、`NODE2_IP=...`、`NODE3_IP=...`；2）在本机执行 `./scripts/bootstrap.sh`（或 `./scripts/gen-patroni.sh`）重新生成 `patroni/patroni.env`；3）检查 `cat patroni/patroni.env` 应包含 `PATRONI_ETCD3_HOSTS=192.168.0.152:2379,192.168.0.153:2379,192.168.0.154:2379`；4）重启 Patroni：`docker compose up -d --force-recreate patroni`。
- **etcd 中 conn_url 一直为 172.18.x**：compose 中 etcd、patroni 使用 **端口映射 + bridge**，通过环境变量将 `PATRONI_POSTGRESQL_CONNECT_ADDRESS`、`PATRONI_RESTAPI_CONNECT_ADDRESS` 设为 NODE_IP，注册到 etcd 的 conn_url 为宿主机地址。HAProxy、PGBouncer 通过 NODE*_IP 连各机 5432/8008。若曾用 host 网络，切到端口映射后需**重建** etcd 与 patroni：`docker compose up -d --force-recreate etcd patroni`。

### etcd "unhealthy cluster" / "failed to commit proposal: context deadline exceeded"

出现该错误说明 **etcd 曾以 3 节点 initial_cluster 启动**，数据目录里仍认为自己是 3 节点之一，在等 etcd2、etcd3 形成 quorum，单节点无法提交，所以一直 unhealthy。

**处理（仅在 Node1 上执行）：清空 etcd 数据并以单节点重新引导**

```bash
./scripts/reset-etcd-node1.sh
```

脚本会：停止 etcd → 清空 `data/etcd` → 以 **单节点**（仅 etcd1）启动 → 执行 `member add` 将 etcd2、etcd3 加入集群。完成后 Node1 的 etcd 会变为健康，再在 Node1 上执行 `./deploy.sh` 继续部署，或在 Node2/Node3 上执行 `./deploy.sh`。

## 节点扩展（快速拓展到 4～6 节点）

当前方案支持 **3～6 节点**，通过 `.env` 中可选 `NODE4_IP`、`NODE5_IP`、`NODE6_IP` 与 `ETCD_INITIAL_CLUSTER` 扩展，无需改代码。

### 扩展流程（以新增第 4 节点为例）

**1. 在现有 3 台节点上统一增加第 4 节点信息**

- 在 **所有现有节点** 的 `.env` 中增加（或取消注释）：
  ```bash
  NODE4_IP=192.168.0.155
  ```
- 在 **所有现有节点** 上重新生成配置并重载 HAProxy、可选重启 Patroni 以连新 etcd：
  ```bash
  ./scripts/bootstrap.sh
  docker compose exec haproxy kill -HUP 1
  # 若希望 Patroni 使用新 etcd 列表，可：docker compose restart patroni
  ```

**2. 在现有 etcd 集群中注册第 4 个 etcd 成员**

在 **任意一台已有节点** 上执行（需替换为实际 NODE4_IP）：

```bash
docker exec etcd etcdctl member add etcd4 --peer-urls=http://192.168.0.155:2380
# 记下输出中的 ETCD_INITIAL_CLUSTER 或按下面步骤在新节点 .env 中设置
```

**3. 在新节点（第 4 台机器）上部署**

- 克隆项目，复制并编辑 `.env`：
  - `NODE_ID=4`
  - `NODE_IP=192.168.0.155`（本机 IP）
  - `NODE1_IP`～`NODE4_IP` 与现有节点一致（含本机）
  - `ETCD_INITIAL_CLUSTER_STATE=existing`
  - 设置完整 etcd 集群列表（可从任意现有节点生成）：
    ```bash
    # 在任意现有节点执行，将输出追加到新节点的 .env
    ./scripts/build-etcd-initial-cluster.sh
    ```
    或手动设置，例如：
    ```bash
    ETCD_INITIAL_CLUSTER=etcd1=http://192.168.0.152:2380,etcd2=http://192.168.0.153:2380,etcd3=http://192.168.0.154:2380,etcd4=http://192.168.0.155:2380
    ```
- 在新节点执行：
  ```bash
  ./scripts/bootstrap.sh
  docker compose up -d etcd
  # etcd 健康后
  docker compose up -d patroni
  docker compose up -d haproxy pgbouncer
  docker compose --profile with-vip up -d keepalived
  ```

**4. 验证**

```bash
docker exec -it etcd etcdctl --endpoints=192.168.0.152:2379,192.168.0.153:2379,192.168.0.154:2379 endpoint status
docker exec -it etcd etcdctl --endpoints=192.168.0.152:2379,192.168.0.153:2379,192.168.0.154:2379 endpoint health --write-out=table
docker exec -it etcd etcdctl --endpoints=192.168.0.152:2379,192.168.0.153:2379,192.168.0.154:2379 get "" --prefix
docker exec patroni patronictl -c /config/patroni.yml list
# 应看到 4 个节点，1 个 Leader、3 个 Replica
```

### 扩展要点小结

| 步骤 | 现有节点 | 新节点 |
|------|----------|--------|
| .env | 增加 `NODE4_IP`，三台一致 | `NODE_ID=4`、`NODE_IP`、`NODE1_IP`～`NODE4_IP`、`ETCD_INITIAL_CLUSTER`（完整列表）、`ETCD_INITIAL_CLUSTER_STATE=existing` |
| etcd | 执行 `etcdctl member add etcd4 ...` | 启动 etcd（existing） |
| 配置 | `./scripts/bootstrap.sh`，重载 HAProxy | `./scripts/bootstrap.sh` 后按顺序启动各服务 |

继续加第 5、6 节点时重复上述流程，在 `.env` 中增加 `NODE5_IP`、`NODE6_IP`，并在 `build-etcd-initial-cluster.sh` 输出中纳入对应 `etcd5`、`etcd6` 即可。

## 安全与生产建议

- 修改默认密码（`.env` 与 `patroni.yml` 中保持一致）。
- 按需收紧 `pg_hba`、防火墙规则。
- 生产环境建议 etcd、Patroni 通信使用 TLS。
- 定期备份与恢复演练。

## 故障排查

### system ID mismatch（节点属于不同集群）

若某节点日志出现 `system ID mismatch, node patroniX belongs to a different cluster: XXXXX != YYYYY`，说明该节点本地 PostgreSQL 数据来自另一次 bootstrap（或曾为主节点），与当前 etcd 中记录的集群不是同一套。**该节点必须清空本地数据并从当前 Leader 重新克隆。**

**处理步骤（仅在该报错节点执行）：**

1. 确认当前 Leader（例如 `patroni2`）：`docker exec patroni patronictl -c /config/patroni.yml list`
2. 在该节点清空数据目录并设置属主，让 Patroni 从当前 Leader 做 basebackup：
   ```bash
   cd patroni-stack
   docker compose stop patroni
   sudo rm -rf ./data/pg/data ./data/pg/*
   mkdir -p ./data/pg
   sudo chown -R 999:999 ./data/pg
   docker compose up -d patroni
   ```
3. 用 `patronictl list` 确认该节点状态变为 `running`（Replica）。

### 从节点 start failed：postmaster.opts / data directory wrong path 或 invalid permissions

若从节点日志出现 `FileNotFoundError: '/home/postgres/data/postmaster.opts'`、`data directory "/home/postgres/data" has wrong ownership` 或 `data directory "/home/postgres/data" has invalid permissions`，说明该节点仍在使用旧数据目录路径 `/home/postgres/data`，而当前配置应为 `/home/postgres/pgdata/data`（与 docker-compose 挂载 `./data/pg:/home/postgres/pgdata` 一致）。**三台节点的 patroni.yml 中 data_dir 必须一致且为 `/home/postgres/pgdata/data`。**

**处理步骤（在每台报错节点上执行）：**

1. **确认使用最新模板并重新生成配置**
   ```bash
   cd patroni-stack
   ./scripts/bootstrap.sh
   grep 'data_dir:' patroni/patroni.yml
   # 必须为：data_dir: /home/postgres/pgdata/data
   ```

2. **清空从节点数据目录并设置属主**（让 Patroni 从主节点重新做 basebackup）
   ```bash
   sudo rm -rf ./data/pg/data ./data/pg/*
   mkdir -p ./data/pg
   sudo chown -R 999:999 ./data/pg
   ```
   （若镜像中 postgres 用户 UID 非 999，可用 `docker run --rm ${PATRONI_IMAGE:-patroni:v4.1.0} id postgres` 查看。）

3. **重启 Patroni**
   ```bash
   docker compose up -d --force-recreate patroni
   ```

4. 用 `docker exec patroni patronictl -c /config/patroni.yml list` 确认从节点状态变为 `running`。

## 已知限制

- 每台仅跑单实例 etcd、单实例 Patroni；支持 3～6 节点扩展（见上文节点扩展）。
- **etcd、Patroni 使用端口映射**：宿主机 2379、2380、5432、8008 端口需空闲（或与映射一致），不能与其他进程冲突。
- VIP 依赖 VRRP，同一二层网络内需能组播/单播；跨机房需单独设计。
