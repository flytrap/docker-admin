# Patroni 配置（由 scripts/gen-patroni.sh 根据 NODE_ID / NODE_IP / .env 生成 patroni.yml）
scope: pg-cluster
namespace: /service/
name: patroni${NODE_ID}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts: ${ETCD_HOSTS}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: true
      use_slots: true
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /home/postgres/pgdata/data
  use_pg_rewind: true
  parameters:
    password_encryption: scram-sha-256
    max_connections: 100
    shared_buffers: 256MB
    effective_cache_size: 1GB
    maintenance_work_mem: 64MB
    checkpoint_completion_target: 0.9
    wal_buffers: 16MB
    default_statistics_target: 100
    random_page_cost: 1.1
    effective_io_concurrency: 200
    work_mem: 4MB
    min_wal_size: 1GB
    max_wal_size: 4GB
  pg_hba:
    - host all all 0.0.0.0/0 scram-sha-256
    - host replication replicator 0.0.0.0/0 scram-sha-256
  authentication:
    superuser:
      username: postgres
      password: ${POSTGRES_SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${POSTGRES_REPLICATION_PASSWORD}
