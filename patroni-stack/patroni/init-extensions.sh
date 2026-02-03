#!/bin/sh
# Patroni post_init：在 managerdb 中创建常用扩展（plsh, postgres_fdw, pg_net, pg_cron, pg_stat_statements）
# 由 bootstrap.post_init 在 initdb 后执行；$1 为 Patroni 传入的 superuser 连接串。
# 使用带插件的镜像时需先构建 docker/Dockerfile.plugin 并设置 PATRONI_IMAGE。
set -e
conn="${1:-postgres}"
DB_NAME="managerdb"
# 创建 managerdb（若已存在则忽略错误及退出码，避免 set -e 导致脚本退出）
(psql -v ON_ERROR_STOP=0 "$conn" -c "CREATE DATABASE $DB_NAME;") || true
# 构造指向 managerdb 的连接串，避免 psql "$conn" -d managerdb 被误解析导致 pg_hba 报错
case "$conn" in
  postgresql://*|postgres://*)
    conn_managerdb=$(echo "$conn" | sed -e 's|/postgres$|/managerdb|' -e 's|/postgres?|/managerdb?|')
    ;;
  *)
    conn_managerdb=$(echo "$conn" | sed 's/dbname=postgres/dbname=managerdb/')
    [ "$conn_managerdb" = "$conn" ] && conn_managerdb="$conn dbname=managerdb"
    ;;
esac
# 在 managerdb 中安装扩展（仅传连接串，不用 -d）
psql -v ON_ERROR_STOP=1 "$conn_managerdb" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS plsh;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOSQL
