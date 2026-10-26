# shellcheck shell=bash
# VLESS + Reality + Vision：固定 TCP 443，回落到本机 Nginx 的自有域名站点（127.0.0.1:31305）

reality_vision_title() { printf 'Reality-Vision'; }
reality_vision_transport() { printf 'tcp'; }

reality_vision_init() {
    local keys
    check_port_free 443 tcp reality-vision
    if [[ -z "$(proto_get reality-vision .privateKey)" ]]; then
        keys=$(reality_keypair)
        proto_set reality-vision '{port: 443, privateKey: $priv, publicKey: $pub, shortId: $sid}' \
            --arg priv "${keys% *}" --arg pub "${keys#* }" --arg sid "$(new_short_id)"
    else
        proto_set reality-vision '{port: 443}'
    fi
}

reality_vision_inbound() {
    jq -n --argjson port "$(proto_get reality-vision .port)" \
        --arg domain "$(state_get .domain)" \
        --arg priv "$(proto_get reality-vision .privateKey)" \
        --arg sid "$(proto_get reality-vision .shortId)" \
        --argjson target "${EZ_REALITY_TARGET_PORT}" \
        --argjson clients "$(vless_clients_json xtls-rprx-vision)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "reality-vision", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none"},
        streamSettings: {
            network: "tcp", security: "reality",
            realitySettings: {
                target: ("127.0.0.1:" + ($target|tostring)), xver: 0,
                serverNames: [$domain], privateKey: $priv, shortIds: [$sid]
            }
        },
        sniffing: $sniffing
    }'
}

reality_vision_link() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&pbk=%s&sid=%s&flow=xtls-rprx-vision#%s\n' \
        "${uuid}" "${domain}" "$(proto_get reality-vision .port)" "${domain}" \
        "$(proto_get reality-vision .publicKey)" "$(proto_get reality-vision .shortId)" \
        "$(urlencode "$(link_name "${name}" Reality)")"
}
