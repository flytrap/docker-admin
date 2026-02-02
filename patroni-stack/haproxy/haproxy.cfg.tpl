# HAProxy 配置（backend 由 gen-haproxy.sh 根据 NODE*_IP 动态生成）
global
    maxconn 2000
    log stdout format raw local0
    stats socket /tmp/haproxy.sock mode 660 level admin
    stats timeout 2m

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client  1m
    timeout server  1m
    option tcplog

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE

frontend pg_write
    bind *:5000
    default_backend pg_primary

backend pg_primary
    mode tcp
    option tcp-check
    tcp-check connect
    option httpchk GET /leader
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
__BACKEND_SERVERS__

frontend pg_read
    bind *:5001
    default_backend pg_replicas

backend pg_replicas
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect
    option httpchk GET /health
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
__BACKEND_SERVERS__
