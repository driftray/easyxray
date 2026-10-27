# shellcheck shell=bash
# VLESS + XHTTP + TLS（自有域名证书）：不走 Reality，不受 Shadowrocket 指纹问题和 Reality 探测影响
# 对外由 Nginx 监听并处理 TLS，XHTTP 路径用 grpc_pass 转给只监听本机的 Xray，其他路径返回伪装站点，
# 避免 Xray 直接暴露在公网上的实现特征（例如路径不对时返回空的 404）

xhttp_tls_title() { printf 'XHTTP-TLS'; }
xhttp_tls_transport() { printf 'tcp'; }
xhttp_tls_listener() { printf 'nginx'; }
xhttp_tls_secrets() { printf '%s\n' path; }

xhttp_tls_init() {
    local port path
    port=$(proto_get xhttp-tls .port)
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port tcp)
    else
        check_port_free "${port}" tcp xhttp-tls
    fi
    path=$(proto_get xhttp-tls .path)
    proto_set xhttp-tls '{port: ($port|tonumber), path: $path}' --arg port "${port}" --arg path "${path:-$(new_path)}"
}

xhttp_tls_inbound() {
    jq -n --argjson port "${EZ_XHTTP_BACKEND_PORT}" \
        --arg domain "$(state_get .domain)" \
        --arg path "$(proto_get xhttp-tls .path)" \
        --argjson clients "$(vless_clients_json '')" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "xhttp-tls", listen: "127.0.0.1", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none"},
        streamSettings: {
            network: "xhttp", security: "none",
            xhttpSettings: {host: $domain, path: $path, mode: "auto"}
        },
        sniffing: $sniffing
    }'
}

xhttp_tls_link() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    # path 必须带前导 /（部分客户端不会自动补全）
    printf 'vless://%s@%s:%s?encryption=none&security=tls&type=xhttp&sni=%s&host=%s&alpn=h2&path=%s&mode=auto#%s\n' \
        "${uuid}" "${domain}" "$(proto_get xhttp-tls .port)" "${domain}" "${domain}" \
        "$(urlencode "$(proto_get xhttp-tls .path)")" "$(urlencode "$(link_name "${name}" XHTTP)")"
}

# Nginx 对外监听的 server 块：TLS 由 Nginx 处理，XHTTP 路径转给 Xray，其他路径返回伪装站点
xhttp_tls_nginx() {
    nginx_tls_server "$(proto_get xhttp-tls .port)" <<EOF
    location ^~ $(proto_get xhttp-tls .path)/ {
        client_max_body_size 0;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:${EZ_XHTTP_BACKEND_PORT};
    }
EOF
}
