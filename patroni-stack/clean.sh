#!/bin/bash
# 清理所有容器及本地数据（慎用）
set -e
cd "$(dirname "$0")"
docker compose down -v
sudo rm -rf data/etcd/*

sudo rm -rf data/pg
mkdir -p data/pg
sudo chown -R 999:999 data/pg
