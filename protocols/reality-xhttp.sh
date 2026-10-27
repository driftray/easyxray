# shellcheck shell=bash
# VLESS + Reality + XHTTP：和 Reality-Vision 共用回落站点，单独生成密钥和 shortId
# Shadowrocket 需要在 设置 → TCP 中选择支持 X25519MLKEM768 的较新 TLS 指纹（例如 chrome140）

reality_xhttp_title() { printf 'Reality-XHTTP'; }
reality_xhttp_transport() { printf 'tcp'; }
reality_xhttp_secrets() { printf '%s\n' privateKey publicKey shortId path; }

reality_xhttp_init() {
    local port keys path
    port=$(proto_get reality-xhttp .port)
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port tcp)
    else
        check_port_free "${port}" tcp reality-xhttp
    fi
    path=$(proto_get reality-xhttp .path)
    if [[ -z "$(proto_get reality-xhttp .privateKey)" ]]; then
        keys=$(reality_keypair)
        proto_set reality-xhttp '{port: ($port|tonumber), path: $path, privateKey: $priv, publicKey: $pub, shortId: $sid}' \
            --arg port "${port}" --arg path "${path:-$(new_path)}" \
            --arg priv "${keys% *}" --arg pub "${keys#* }" --arg sid "$(new_short_id)"
    else
        proto_set reality-xhttp '{port: ($port|tonumber), path: $path}' --arg port "${port}" --arg path "${path}"
    fi
}

reality_xhttp_inbound() {
    jq -n --argjson port "$(proto_get reality-xhttp .port)" \
        --arg domain "$(state_get .domain)" \
        --arg priv "$(proto_get reality-xhttp .privateKey)" \
        --arg sid "$(proto_get reality-xhttp .shortId)" \
        --arg path "$(proto_get reality-xhttp .path)" \
        --argjson target "${EZ_REALITY_TARGET_PORT}" \
        --argjson clients "$(vless_clients_json '')" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "reality-xhttp", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none"},
        streamSettings: {
            network: "xhttp", security: "reality",
            realitySettings: {
                target: ("127.0.0.1:" + ($target|tostring)), xver: 0,
                serverNames: [$domain], privateKey: $priv, shortIds: [$sid]
            },
            xhttpSettings: {host: $domain, path: $path, mode: "auto"}
        },
        sniffing: $sniffing
    }'
}

reality_xhttp_link() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=xhttp&sni=%s&host=%s&alpn=h2&path=%s&mode=auto&pbk=%s&sid=%s#%s\n' \
        "${uuid}" "${domain}" "$(proto_get reality-xhttp .port)" "${domain}" "${domain}" \
        "$(urlencode "$(proto_get reality-xhttp .path)")" \
        "$(proto_get reality-xhttp .publicKey)" "$(proto_get reality-xhttp .shortId)" \
        "$(urlencode "$(link_name "${name}" RealityXHTTP)")"
}
