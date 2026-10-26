# shellcheck shell=bash
# Hysteria2 + Salamander 混淆（UDP）：混淆后数据包没有 QUIC 特征，可以绕过运营商针对 QUIC 的限速
# 带宽由客户端填写（Brutal 拥塞控制按客户端声明的带宽发送），服务端不需要设置

hysteria2_title() { printf 'Hysteria2'; }
hysteria2_transport() { printf 'udp'; }

hysteria2_init() {
    local port
    port=$(proto_get hysteria2 .port)
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port udp)
    else
        check_port_free "${port}" udp hysteria2
    fi
    if [[ -z "$(proto_get hysteria2 .obfsPassword)" ]]; then
        proto_set hysteria2 '{port: ($port|tonumber), obfsPassword: $obfs}' --arg port "${port}" --arg obfs "$(rand_hex 16)"
    else
        proto_set hysteria2 '{port: ($port|tonumber)}' --arg port "${port}"
    fi
}

hysteria2_inbound() {
    jq -n --argjson port "$(proto_get hysteria2 .port)" \
        --arg domain "$(state_get .domain)" --arg cert "$(cert_file)" --arg key "$(key_file)" \
        --arg obfs "$(proto_get hysteria2 .obfsPassword)" \
        --argjson users "$(hysteria_users_json)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "hysteria2", port: $port, protocol: "hysteria",
        settings: {version: 2, users: $users},
        streamSettings: {
            network: "hysteria", security: "tls",
            tlsSettings: {serverName: $domain, alpn: ["h3"], certificates: [{certificateFile: $cert, keyFile: $key}]},
            hysteriaSettings: {version: 2, udpIdleTimeout: 60},
            finalmask: {udp: [{type: "salamander", settings: {password: $obfs}}]}
        },
        sniffing: $sniffing
    }'
}

hysteria2_link() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=0&obfs=salamander&obfs-password=%s#%s\n' \
        "${uuid}" "${domain}" "$(proto_get hysteria2 .port)" "${domain}" \
        "$(proto_get hysteria2 .obfsPassword)" "$(urlencode "$(link_name "${name}" Hy2)")"
}
