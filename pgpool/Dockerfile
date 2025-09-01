FROM bitnami/postgresql:17

USER root

# 确保 postgres 组存在，并调整 postgres 用户的主组
# RUN groupadd -f postgres && usermod -g postgres postgres

# 安装构建工具
RUN apt-get update && apt-get install -y --no-install-recommends \
       build-essential \
       git \
       curl \
       libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# 安装 pg_cron 和 plsh
# RUN apt-get update && apt-get install -y \
#     postgresql-17-cron \
#     postgresql-17-plsh \
#  && rm -rf /var/lib/apt/lists/*

# 编译安装 pg_net
RUN git clone --branch v0.14.0 https://github.com/supabase/pg_net.git /tmp/pg_net \
 && cd /tmp/pg_net \
 && make \
 && make install \
 && rm -rf /tmp/pg_net

# 安装 pg_cron
RUN git clone https://github.com/citusdata/pg_cron.git /tmp/pg_cron \
 && cd /tmp/pg_cron \
 && make \
 && make install \
 && rm -rf /tmp/pg_cron

# 安装 plsh
RUN git clone https://github.com/petere/plsh.git /tmp/plsh \
 && cd /tmp/plsh \
 && make \
 && make install \
 && rm -rf /tmp/plsh

USER 1001

# 初始化扩展
COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql

