#!/bin/bash
# 根据 .env 生成 pgbouncer/userlist.txt（auth_user 及密码，供 pgbouncer.ini auth_file 使用）
set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "缺少 .env"; exit 1; }
source .env
mkdir -p pgbouncer
# userlist 格式: "username" "password"（auth_user 明文，用于 auth_query 连接后端）
pass="${POSTGRESQL_PASSWORD:-flytrap}"
# 若密码含双引号，替换为 \"
pass="${pass//\"/\\\"}"
printf '"postgres" "%s"\n' "$pass" | tr -d '\r' > pgbouncer/userlist.txt
echo "已生成 pgbouncer/userlist.txt"
