# shellcheck shell=bash
# VLESS + Reality + Vision：固定 TCP 443，回落到本机 Nginx 的自有域名站点（127.0.0.1:31305）；
# 无域名模式回落到第三方网站（realityTarget）

reality_vision_title() { printf 'Reality-Vision'; }
reality_vision_transport() { printf 'tcp'; }
reality_vision_secrets() { printf '%s\n' privateKey publicKey shortId; }

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
        --arg sni "$(reality_sni)" --arg dest "$(reality_dest)" \
        --arg priv "$(proto_get reality-vision .privateKey)" \
        --arg sid "$(proto_get reality-vision .shortId)" \
        --argjson clients "$(vless_clients_json xtls-rprx-vision)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "reality-vision", port: $port, protocol: "vless",
        settings: {clients: $clients, decryption: "none"},
        streamSettings: {
            network: "tcp", security: "reality",
            realitySettings: {
                target: $dest, xver: 0,
                serverNames: [$sni], privateKey: $priv, shortIds: [$sid]
            }
        },
        sniffing: $sniffing
    }'
}

reality_vision_link() {
    local uuid=$1 name=$2
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&pbk=%s&sid=%s&flow=xtls-rprx-vision#%s\n' \
        "${uuid}" "$(server_addr)" "$(proto_get reality-vision .port)" "$(reality_sni)" \
        "$(proto_get reality-vision .publicKey)" "$(proto_get reality-vision .shortId)" \
        "$(urlencode "$(link_name "${name}" Reality)")"
}

# mihomo 连 Reality 必须用 chrome 指纹并打开 support-x25519mlkem768（Xray 26.9.8 起 Reality 的要求）
reality_vision_mihomo() {
    local uuid=$1 name=$2
    cat <<EOF
  - name: "$(link_name "${name}" Reality)"
    type: vless
    server: $(server_addr)
    port: $(proto_get reality-vision .port)
    uuid: ${uuid}
    network: tcp
    flow: xtls-rprx-vision
    packet-encoding: xudp
    udp: true
    tls: true
    servername: $(reality_sni)
    client-fingerprint: chrome
    reality-opts:
      public-key: $(proto_get reality-vision .publicKey)
      short-id: $(proto_get reality-vision .shortId)
      support-x25519mlkem768: true
EOF
}
