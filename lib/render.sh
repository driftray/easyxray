# shellcheck shell=bash
# 根据状态文件生成 Xray 配置和订阅文件。只读状态，不修改任何东西；输出到指定目录

# 出口：direct（默认，优先 IPv4）、block，以及状态文件里的 WARP 出口
outbounds_json() {
    jq -c '
        [
            {tag: "direct", protocol: "freedom", streamSettings: {sockopt: {domainStrategy: "UseIPv4v6"}}},
            {tag: "block", protocol: "blackhole"}
        ] +
        [(.outbounds // {}) | to_entries[] | select(.value.type == "warp") | .key as $tag | .value | {
            tag: $tag, protocol: "wireguard",
            settings: {
                secretKey: .privateKey,
                # warp-ipv4 只配 IPv4 地址：配了 IPv6 地址时，内核 TUN 会为它添加 IPv6 策略路由，重启后还会残留
                address: (if $tag == "warp-ipv6" then [.addressV6] else [.addressV4] end | map(select(. != null and . != ""))),
                peers: [{publicKey: .peerPublicKey, allowedIPs: ["0.0.0.0/0", "::/0"], endpoint: .endpoint}],
                reserved: .reserved,
                mtu: 1280,
                domainStrategy: (if $tag == "warp-ipv6" then "ForceIPv6" else "ForceIPv4" end)
            }
        }]
    ' "${EZ_STATE}"
}

# 分流：QUIC 屏蔽（开启时排在最前）→ 用户规则（按添加顺序）；指向不存在出口的规则不生成
routing_json() {
    jq -c '
        (["direct", "block"] + ((.outbounds // {}) | keys)) as $outs |
        ([.routing.rules[]? | select(.outbound as $o | $outs | index($o))]) as $rules |
        {
            domainStrategy: (if any($rules[]; (.ips // []) | length > 0) then "IPIfNonMatch" else "AsIs" end),
            rules: (
                # BT 屏蔽默认开启（旧版本的状态文件没有这一项）。只能识别未加密的 BT
                (if .routing.blockBT != false then [{type: "field", protocol: ["bittorrent"], outboundTag: "block"}] else [] end) +
                (if .routing.blockQUIC then [{type: "field", network: "udp", port: "443", outboundTag: "block"}] else [] end) +
                [$rules[] | (
                    (if (.domains // []) | length > 0 then {type: "field", domain: .domains, outboundTag: .outbound} else empty end),
                    (if (.ips // []) | length > 0 then {type: "field", ip: .ips, outboundTag: .outbound} else empty end)
                )]
            )
        }
    ' "${EZ_STATE}"
}

log_json() {
    local level access
    level=$(state_get '.system.logLevel')
    access=none
    [[ "${level}" == "debug" ]] && access="${EZ_LOG}/access.log"
    jq -nc --arg level "${level:-warning}" --arg error "${EZ_LOG}/error.log" --arg access "${access}" \
        '{loglevel: $level, error: $error, access: $access, dnsLog: false}'
}

# 输出完整的 Xray 配置
xray_config_json() {
    local p inbounds='[]' inbound
    while read -r p; do
        [[ -z "${p}" ]] && continue
        inbound=$(proto_call "${p}" inbound) || die "生成 ${p} 的入站配置失败"
        inbounds=$(jq -c --argjson i "${inbound}" '. + [$i]' <<<"${inbounds}")
    done < <(enabled_protocols)
    jq -n --argjson log "$(log_json)" --argjson inbounds "${inbounds}" \
        --argjson outbounds "$(outbounds_json)" --argjson routing "$(routing_json)" \
        '{log: $log, inbounds: $inbounds, outbounds: $outbounds, routing: $routing}'
}

# 一个用户的全部分享链接
user_links() {
    local uuid=$1 email=$2 p
    while read -r p; do
        [[ -z "${p}" ]] && continue
        proto_call "${p}" link "${uuid}" "${email}"
    done < <(enabled_protocols)
}

# 生成订阅文件：每个用户一个，文件名是该用户的随机令牌，内容为 base64 编码的链接列表
render_subscriptions() {
    local outdir=$1 uuid email token
    mkdir -p "${outdir}"
    while IFS=$'\t' read -r uuid email token; do
        [[ -z "${token}" ]] && continue
        user_links "${uuid}" "${email}" | base64 | tr -d '\n' >"${outdir}/${token}"
    done < <(jq -r '.users[] | [.uuid, .email, .subToken] | @tsv' "${EZ_STATE}")
}
