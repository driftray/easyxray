# shellcheck shell=bash
# Hysteria2（UDP）。默认端口在 FaceTime 使用的 UDP 端口段（16384-16402）里随机选
# 可以调整的设置（ezx protocol set hysteria2 …），从旧版本升级时都保持原样：
#   port  监听端口
#   obfs  Salamander 混淆：数据包没有 QUIC 特征，可以绕过针对 QUIC 的限速，但也不再像 HTTP/3，且更耗 CPU。默认关闭
#   hop   端口跳跃：服务端用 nftables 把一段 UDP 端口转发到监听端口，客户端每隔一段时间换一个端口连接
# 带宽由客户端填写（Brutal 拥塞控制按客户端声明的带宽发送），服务端不需要设置

hysteria2_title() { printf 'Hysteria2'; }
hysteria2_transport() { printf 'udp'; }
hysteria2_secrets() { printf '%s\n' obfsPassword; }

hysteria2_init() {
    local port obfs
    port=$(proto_get hysteria2 .port)
    if [[ -z "${port}" ]]; then
        port=$(pick_random_port udp "${EZ_HY2_PORT_RANGE}" 2>/dev/null) || port=$(pick_random_port udp)
    else
        check_port_free "${port}" udp hysteria2
    fi
    # 新安装默认不混淆；已有的配置保持原样（见 hysteria2_obfs_on）
    if hysteria2_obfs_on; then obfs=true; else obfs=false; fi
    # 混淆密码总是生成好，以后打开混淆时不用重新生成
    if [[ -z "$(proto_get hysteria2 .obfsPassword)" ]]; then
        proto_set hysteria2 '{port: ($port|tonumber), obfs: ($obfs == "true"), obfsPassword: $pw}' \
            --arg port "${port}" --arg obfs "${obfs}" --arg pw "$(rand_hex 16)"
    else
        proto_set hysteria2 '{port: ($port|tonumber), obfs: ($obfs == "true")}' --arg port "${port}" --arg obfs "${obfs}"
    fi
}

# 0.7.0 之前的版本一直开着混淆，状态文件里没有 obfs 这一项，只有混淆密码：升级后保持开启，客户端不用改
hysteria2_obfs_on() {
    [[ "$(jq -r '(.protocols.hysteria2 // {}) | if has("obfs") then .obfs else (.obfsPassword != null) end' "${EZ_STATE}")" == "true" ]]
}
# 端口跳跃的范围，例如 16384-16402；没有开启时为空
hysteria2_hop_ports() { proto_get hysteria2 .hopPorts; }

hysteria2_inbound() {
    local mask='{}'
    hysteria2_obfs_on && mask=$(jq -nc --arg pw "$(proto_get hysteria2 .obfsPassword)" '{finalmask: {udp: [{type: "salamander", settings: {password: $pw}}]}}')
    jq -n --argjson port "$(proto_get hysteria2 .port)" \
        --arg domain "$(state_get .domain)" --arg cert "$(cert_file)" --arg key "$(key_file)" \
        --argjson mask "${mask}" \
        --argjson users "$(hysteria_users_json)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "hysteria2", port: $port, protocol: "hysteria",
        settings: {version: 2, users: $users},
        streamSettings: ({
            network: "hysteria", security: "tls",
            tlsSettings: {serverName: $domain, alpn: ["h3"], certificates: [{certificateFile: $cert, keyFile: $key}]},
            hysteriaSettings: {version: 2, udpIdleTimeout: 60}
        } + $mask),
        sniffing: $sniffing
    }'
}

# 端口跳跃用 mport 参数（Shadowrocket、v2rayN 都能识别）
hysteria2_link() {
    local uuid=$1 name=$2 domain extra=''
    domain=$(state_get .domain)
    hysteria2_obfs_on && extra+="&obfs=salamander&obfs-password=$(proto_get hysteria2 .obfsPassword)"
    [[ -n "$(hysteria2_hop_ports)" ]] && extra+="&mport=$(hysteria2_hop_ports)"
    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=0%s#%s\n' \
        "${uuid}" "${domain}" "$(proto_get hysteria2 .port)" "${domain}" "${extra}" \
        "$(urlencode "$(link_name "${name}" Hy2)")"
}

hysteria2_mihomo() {
    local uuid=$1 name=$2 domain
    domain=$(state_get .domain)
    cat <<EOF
  - name: "$(link_name "${name}" Hy2)"
    type: hysteria2
    server: ${domain}
    port: $(proto_get hysteria2 .port)
    password: ${uuid}
    sni: ${domain}
    alpn: [h3]
EOF
    if hysteria2_obfs_on; then
        printf '    obfs: salamander\n    obfs-password: %s\n' "$(proto_get hysteria2 .obfsPassword)"
    fi
    if [[ -n "$(hysteria2_hop_ports)" ]]; then
        printf '    ports: %s\n    hop-interval: 30\n' "$(hysteria2_hop_ports)"
    fi
}

# ---------- 设置 ----------

hysteria2_set_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "端口不正确：${port}"
    check_port_free "${port}" udp hysteria2
    proto_set hysteria2 '{port: ($port|tonumber)}' --arg port "${port}"
}

hysteria2_set_obfs() {
    proto_set hysteria2 '{obfs: ($v == "on")}' --arg v "$1"
}

# 打开端口跳跃：$1=范围（默认 FaceTime 端口段）；off 关闭
hysteria2_set_hop() {
    local range=${1:-${EZ_HY2_PORT_RANGE}} low high port self p
    if [[ "${range}" == off ]]; then
        state_update 'del(.protocols.hysteria2.hopPorts)'
        return 0
    fi
    low=${range%-*}
    high=${range#*-}
    [[ "${range}" =~ ^[0-9]+-[0-9]+$ ]] && ((low >= 1024 && high <= 65535 && low < high && high - low <= 1000)) ||
        die "端口范围不正确：${range}（例如 16384-16402，最多 1000 个端口，不能低于 1024）"
    self=$(proto_get hysteria2 .port)
    # 范围内的 UDP 端口都会被转发给 Hysteria2，不能有其他程序在用
    for ((port = low; port <= high; port++)); do
        [[ "${port}" == "${self}" ]] && continue
        if port_in_use "${port}" udp; then
            die "UDP ${port} 已被 $(port_owner_desc "${port}" udp) 占用，不能用于端口跳跃，请换一个范围"
        fi
    done
    while read -r p; do
        [[ "${p}" == hysteria2 || "$(proto_call "${p}" transport)" != udp ]] && continue
        port=$(proto_get "${p}" .port)
        ((port >= low && port <= high)) && die "UDP ${port} 已经分配给 $(proto_call "${p}" title)，请换一个范围"
    done < <(enabled_protocols)
    proto_set hysteria2 '{hopPorts: $r}' --arg r "${range}"
}
