# shellcheck shell=bash
# VLESS + XHTTP + TLS（自有域名证书）：不走 Reality，不受 Shadowrocket 指纹问题和 Reality 探测影响

xhttp_tls_title() { printf 'XHTTP-TLS'; }
xhttp_tls_transport() { printf 'tcp'; }

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
    jq -n --argjson port "$(proto_get xhttp-tls .port)" \
        --arg domain "$(state_get .domain)" --arg cert "$(cert_file)" --arg key "$(key_file)" \
        --arg path "$(proto_get xhttp-tls .path)" \
        --argjson clients "$(vless_clients_json '')" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "xhttp-tls", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none"},
        streamSettings: {
            network: "xhttp", security: "tls",
            tlsSettings: {serverName: $domain, rejectUnknownSni: true, minVersion: "1.2", alpn: ["h2", "http/1.1"],
                certificates: [{certificateFile: $cert, keyFile: $key}]},
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
