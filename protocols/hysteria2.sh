# shellcheck shell=bash
# Hysteria2（UDP）。默认端口在 FaceTime 使用的 UDP 端口段（16384-16402）里随机选
# 可以调整的设置（ezx protocol set hysteria2 …），从旧版本升级时都保持原样：
#   port  监听端口
#   obfs  Salamander 混淆：数据包没有 QUIC 特征，可以绕过针对 QUIC 的限速，但也不再像 HTTP/3，且更耗 CPU。默认关闭
#   hop   端口跳跃：服务端用 nftables 把一段 UDP 端口转发到监听端口，客户端每隔一段时间换一个端口连接
#   bandwidth  服务器的上下行带宽（Mbps）。默认不设置，用 BBR。丢包率高的线路可以设置：服务端和客户端都填了才会启用 Brutal，
#              按两边的较小值固定速率发送；只填一端时 Xray 仍然用 BBR
# 没有通过认证的 HTTP/3 请求（例如主动探测）返回和 Nginx 一样的伪装站，不是所有路径都 404

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
# 服务端带宽，输出「上行 下行」（Mbps）；没有设置时为空
hysteria2_bandwidth() { jq -r '.protocols.hysteria2.bandwidth // empty | "\(.up) \(.down)"' "${EZ_STATE}"; }

hysteria2_inbound() {
    local mask
    # 混淆和带宽都放在 finalmask 里，两项都没有时不写这个字段
    mask=$(jq -c --arg obfs "$(hysteria2_obfs_on && echo 1)" '.protocols.hysteria2 as $h | {}
        | if $obfs == "1" then .udp = [{type: "salamander", settings: {password: $h.obfsPassword}}] else . end
        | if $h.bandwidth then .quicParams = {brutalUp: "\($h.bandwidth.up) mbps", brutalDown: "\($h.bandwidth.down) mbps"} else . end
        | if . == {} then . else {finalmask: .} end' "${EZ_STATE}")
    jq -n --argjson port "$(proto_get hysteria2 .port)" \
        --arg domain "$(state_get .domain)" --arg cert "$(cert_file)" --arg key "$(key_file)" \
        --arg site "${EZ_WWW}/site" --argjson mask "${mask}" \
        --argjson users "$(hysteria_users_json)" \
        --argjson sniffing "$(sniffing_json)" '{
        tag: "hysteria2", port: $port, protocol: "hysteria",
        settings: {version: 2, users: $users},
        streamSettings: ({
            network: "hysteria", security: "tls",
            tlsSettings: {serverName: $domain, alpn: ["h3"], certificates: [{certificateFile: $cert, keyFile: $key}]},
            hysteriaSettings: {version: 2, udpIdleTimeout: 60, masquerade: {type: "file", dir: $site}}
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

hysteria2_valid_mbps() { [[ "${1:-}" =~ ^[1-9][0-9]{0,5}$ ]] && (($1 <= 100000)); }

# 设置服务端带宽：$1=上行 $2=下行（Mbps）；off 清除
hysteria2_set_bandwidth() {
    if [[ "$1" == off ]]; then
        state_update 'del(.protocols.hysteria2.bandwidth)'
        return 0
    fi
    hysteria2_valid_mbps "$1" && hysteria2_valid_mbps "${2:-}" ||
        die "带宽不正确：${1} ${2:-}（上行 下行，单位 Mbps，1-100000，例如 1000 1000）"
    proto_set hysteria2 '{bandwidth: {up: ($up|tonumber), down: ($down|tonumber)}}' --arg up "$1" --arg down "$2"
}

# 同时开 4 个连接测 8 秒，输出总速率（Mbps）：$1=下载地址，或 $1=上传地址 $2=上传的文件
hysteria2_speed() {
    local url=$1 file=${2:-} i
    {
        for i in 1 2 3 4; do
            if [[ -n "${file}" ]]; then
                curl -s -o /dev/null -m 8 -A "${EZ_TARGET_UA}" -X POST -T "${file}" -w '%{speed_upload}\n' "${url}" </dev/null &
            else
                curl -s -o /dev/null -m 8 -A "${EZ_TARGET_UA}" -w '%{speed_download}\n' "${url}" </dev/null &
            fi
        done
        wait
    } | awk '{s += $1} END {printf "%d", s * 8 / 1000000}'
}

# 到就近的 Speedtest 节点测本机带宽，输出「上行 下行」（Mbps）；失败返回 1
hysteria2_speedtest() {
    no_system && return 1
    local tmp host up=0 down=0
    tmp=$(mktemp -d)
    # 稀疏文件，不占磁盘空间
    truncate -s 200M "${tmp}/up"
    while read -r host; do
        down=$(hysteria2_speed "https://${host}/download?size=200000000")
        up=$(hysteria2_speed "https://${host}/upload" "${tmp}/up")
        ((up > 0 && down > 0)) && break
    done < <(curl -fsS -m 10 -A "${EZ_TARGET_UA}" 'https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=3' 2>/dev/null |
        jq -r '.[]? | select(.https_functional == 1) | .host' 2>/dev/null)
    rm -rf "${tmp}"
    ((up > 0 && down > 0)) || return 1
    printf '%s %s\n' "${up}" "${down}"
}
