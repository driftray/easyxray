# shellcheck shell=bash
# WARP 出口：直接调用 Cloudflare 的设备注册接口（与 1.1.1.1 App 相同），不需要 Cloudflare 账号，也不依赖第三方程序
# Xray 使用内核 TUN（不设 noKernelTun），CPU 占用比用户态网络栈低很多

EZ_WARP_API=https://api.cloudflareclient.com/v0a2158/reg
EZ_WARP_ENDPOINT=162.159.192.1:2408

# 注册一个 WARP 设备并写进 .outbounds["warp-ipv4"]
warp_setup_state() {
    local tag=${1:-warp-ipv4} keys priv pub resp peer v4 v6 client_id reserved
    keys=$("${EZ_XRAY_BIN}" wg) || die "生成 WireGuard 密钥失败"
    priv=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"${keys}")
    pub=$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"${keys}")
    [[ -n "${priv}" && -n "${pub}" ]] || die "无法解析 xray wg 的输出"

    info "向 Cloudflare 注册 WARP 设备..."
    resp=$(curl -fsS -m 20 -X POST "${EZ_WARP_API}" \
        -H 'Content-Type: application/json' -H 'CF-Client-Version: a-6.30-3596' \
        -d "$(jq -nc --arg key "${pub}" --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
            '{key: $key, install_id: "", fcm_token: "", tos: $tos, type: "Android", model: "PC", locale: "en_US"}')") ||
        die "WARP 注册失败：无法访问 ${EZ_WARP_API}"

    peer=$(jq -r '.config.peers[0].public_key // empty' <<<"${resp}")
    v4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"${resp}")
    v6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"${resp}")
    client_id=$(jq -r '.config.client_id // empty' <<<"${resp}")
    [[ -n "${peer}" && -n "${v4}" && -n "${client_id}" ]] || die "WARP 注册返回的数据不完整"
    # client_id 是 base64 编码的 3 个字节，作为 WireGuard 的 reserved 字段
    reserved=$(printf '%s' "${client_id}" | base64 -d 2>/dev/null | od -An -tu1 | xargs | jq -Rc 'split(" ") | map(tonumber)')

    state_update '.outbounds[$tag] = {type: "warp", privateKey: $priv, peerPublicKey: $peer,
            addressV4: ($v4 + "/32"), addressV6: (if $v6 == "" then "" else $v6 + "/128" end),
            reserved: $reserved, endpoint: $endpoint, registeredAt: $now}' \
        --arg tag "${tag}" --arg priv "${priv}" --arg peer "${peer}" --arg v4 "${v4}" --arg v6 "${v6}" \
        --argjson reserved "${reserved}" --arg endpoint "${EZ_WARP_ENDPOINT}" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# 开启 WARP 时默认分流的规则
EZ_WARP_DEFAULT_RULES="geosite:cn,geoip:cn"

# 注册 WARP，并在还没有 WARP 规则时加上默认规则
warp_enable_state() {
    warp_setup_state warp-ipv4
    if [[ "$(jq '[.routing.rules[]? | select(.outbound == "warp-ipv4")] | length' "${EZ_STATE}")" -eq 0 ]]; then
        route_add_state warp-ipv4 "${EZ_WARP_DEFAULT_RULES}"
    fi
}

# 删除 WARP 出口和指向它的分流规则
warp_remove_state() {
    local tag=${1:-warp-ipv4}
    state_update 'del(.outbounds[$tag]) | .routing.rules |= map(select(.outbound != $tag))' --arg tag "${tag}"
}
