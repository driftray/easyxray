# shellcheck shell=bash
# 端口分配：Reality-Vision 固定 443，其他协议在范围内随机选空闲端口，选好后写进状态文件不再变化

# 端口是否被系统上的程序占用：$1=端口 $2=tcp|udp
port_in_use() {
    local port=$1 proto=$2 flag=-t
    [[ "${proto}" == "udp" ]] && flag=-u
    if command -v ss >/dev/null 2>&1; then
        [[ -n "$(ss -Hln "${flag}" "sport = :${port}" 2>/dev/null)" ]]
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -i "${proto}:${port}" 2>/dev/null | grep -qE 'LISTEN|UDP'
    else
        return 1
    fi
}

# 占用端口的程序名，用于提示
port_owner() {
    local port=$1 proto=$2 flag=-t
    [[ "${proto}" == "udp" ]] && flag=-u
    ss -Hlnp "${flag}" "sport = :${port}" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/users:(("//; s/"$//'
}

# 状态文件里已经分配给各协议的端口
assigned_ports() {
    jq -r '[.protocols[]?.port // empty] | .[]' "${EZ_STATE}" 2>/dev/null
}

port_assigned() {
    assigned_ports | grep -qx "$1"
}

# 在 portRange 内随机选一个空闲端口：$1=tcp|udp
pick_random_port() {
    local proto=$1 range low high port tries
    range=$(state_get '.portRange')
    range=${range:-${EZ_PORT_RANGE_DEFAULT}}
    low=${range%-*}
    high=${range#*-}
    [[ "${low}" =~ ^[0-9]+$ && "${high}" =~ ^[0-9]+$ ]] && ((low >= 1 && high <= 65535 && low <= high)) ||
        die "端口范围不正确：${range}"
    for ((tries = 0; tries < 500; tries++)); do
        port=$((low + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % (high - low + 1)))
        port_assigned "${port}" && continue
        port_in_use "${port}" tcp && continue
        port_in_use "${port}" udp && continue
        printf '%s\n' "${port}"
        return 0
    done
    die "端口范围 ${range} 内没有空闲端口，请用 --port-range 换一个范围"
}

# 检查指定端口是否可以给协议使用：$1=端口 $2=tcp|udp $3=协议名（重新启用同一协议时允许沿用自己的端口）
check_port_free() {
    local port=$1 proto=$2 self=$3 owner current
    current=$(jq -r --arg p "${self}" '.protocols[$p].port // empty' "${EZ_STATE}")
    if port_assigned "${port}" && [[ "${current}" != "${port}" ]]; then
        die "端口 ${port} 已经分配给其他协议"
    fi
    if port_in_use "${port}" "${proto}"; then
        owner=$(port_owner "${port}" "${proto}")
        # 端口被本程序占用（例如重新生成配置时，由 Xray 或 Nginx 监听），可以继续使用
        [[ "${current}" == "${port}" && ( "${owner}" == "xray" || "${owner}" == "nginx" ) ]] && return 0
        die "${proto^^} ${port} 已被 ${owner:-其他程序} 占用。请先停止占用的程序，或换一个端口"
    fi
}
