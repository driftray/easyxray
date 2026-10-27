# shellcheck shell=bash
# VLESS + TLS + Vision（自有域名证书）：未认证的连接回落到本机 Nginx 的明文站点
# 和正常网站一样同时支持 h2 和 http/1.1：协商出 h2 时回落到 HTTP/2 站点（31308），否则回落到 31306
# dest 写明 127.0.0.1：只写端口时 Xray 会连 localhost，可能先尝试 ::1，而 Nginx 只监听 127.0.0.1

vless_tls_vision_title() { printf 'VLESS-TLS-Vision'; }
vless_tls_vision_transport() { printf 'tcp'; }

vless_tls_vision_init() {
    local port
    port=$(proto_get vless-tls-vision .port)
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port tcp)
    else
        check_port_free "${port}" tcp vless-tls-vision
    fi
    proto_set vless-tls-vision '{port: ($port|tonumber)}' --arg port "${port}"
}

vless_tls_vision_inbound() {
    jq -n --argjson port "$(proto_get vless-tls-vision .port)" \
        --arg domain "$(state_get .domain)" --arg cert "$(cert_file)" --arg key "$(key_file)" \
        --argjson fallback "${EZ_VISION_FALLBACK_PORT}" --argjson fallback_h2 "${EZ_VISION_H2_FALLBACK_PORT}" \
        --argjson clients "$(vless_clients_json xtls-rprx-vision)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "vless-tls-vision", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none", fallbacks: [{alpn: "h2", dest: ("127.0.0.1:" + ($fallback_h2|tostring))}, {dest: ("127.0.0.1:" + ($fallback|tostring))}]},
        streamSettings: {
            network: "tcp", security: "tls",
            tlsSettings: {serverName: $domain, rejectUnknownSni: true, minVersion: "1.2", alpn: ["h2", "http/1.1"],
                certificates: [{certificateFile: $cert, keyFile: $key}]}
        },
        sniffing: $sniffing
    }'
}

vless_tls_vision_link() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    printf 'vless://%s@%s:%s?encryption=none&security=tls&type=tcp&sni=%s&flow=xtls-rprx-vision#%s\n' \
        "${uuid}" "${domain}" "$(proto_get vless-tls-vision .port)" "${domain}" \
        "$(urlencode "$(link_name "${name}" Vision)")"
}
