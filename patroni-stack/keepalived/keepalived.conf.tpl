# Keepalived 配置（由 scripts/gen-keepalived.sh 根据 .env 生成 keepalived.conf）
# 每台节点生成后 STATE/PRIORITY 不同，实现 VIP 漂移

global_defs {
    router_id patroni_node_${NODE_ID}
    enable_script_security
    script_user root
}

# 可选：本机 HAProxy 存活时才持有 VIP（需镜像内具备 curl/nc）
vrrp_script chk_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state ${KEEPALIVED_STATE}
    interface ${KEEPALIVED_INTERFACE}
    virtual_router_id ${KEEPALIVED_ROUTER_ID}
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/${VIP_PREFIX}
    }
    track_script {
        chk_haproxy
    }
}
