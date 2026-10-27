# shellcheck shell=bash
# 协议模块的公共部分。每个协议文件（protocols/*.sh）定义以下函数，函数名前缀为协议名中的 - 换成 _：
#   <p>_title           显示名称
#   <p>_transport       tcp 或 udp
#   <p>_init            首次启用时生成端口、密钥等参数，写进状态文件
#   <p>_inbound         输出 Xray 入站配置（JSON）
#   <p>_link UUID NAME  输出分享链接（不带 fp，客户端用自己的默认指纹）

# 按菜单顺序排列；推荐安装只装前两个
EZ_PROTOCOLS=(reality-vision hysteria2 xhttp-tls reality-xhttp vless-tls-vision)
EZ_PROTOCOLS_RECOMMENDED=(reality-vision hysteria2)

proto_fn() { printf '%s_%s' "${1//-/_}" "$2"; }
proto_call() {
    local p=$1 fn=$2
    shift 2
    "$(proto_fn "${p}" "${fn}")" "$@"
}

# 对外监听协议端口的程序：默认是 Xray，协议可以用 <协议>_listener 改成 nginx
proto_listener() {
    local fn
    fn=$(proto_fn "$1" listener)
    if declare -F "${fn}" >/dev/null; then "${fn}"; else printf 'xray'; fi
}

proto_get() { jq -r --arg p "$1" ".protocols[\$p]$2 // empty" "${EZ_STATE}"; }

# 把参数写进 .protocols[协议]：proto_set 协议 '{port: 443}' [--arg ...]
proto_set() {
    local p=$1 obj=$2
    shift 2
    state_update ".protocols[\$p] = ((.protocols[\$p] // {}) + ${obj})" --arg p "${p}" "$@"
}

cert_file() { printf '%s/%s.crt' "${EZ_TLS}" "$(state_get '.domain')"; }
key_file() { printf '%s/%s.key' "${EZ_TLS}" "$(state_get '.domain')"; }

# 各协议入站的用户列表。$1=flow（可为空）；email 直接用用户邮箱
vless_clients_json() {
    jq -c --arg flow "$1" '[.users[] | {id: .uuid, email: .email} + (if $flow != "" then {flow: $flow} else {} end)]' "${EZ_STATE}"
}
hysteria_users_json() {
    jq -c '[.users[] | {auth: .uuid, email: .email}]' "${EZ_STATE}"
}

# 入站统一开启嗅探：只用于分流，不改写目标地址
sniffing_json() {
    printf '%s' '{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
}

# 生成 Reality 密钥对，输出 "私钥 公钥"。兼容新旧两种 xray x25519 输出格式
reality_keypair() {
    local out priv pub
    out=$("${EZ_XRAY_BIN}" x25519) || die "生成 Reality 密钥失败"
    priv=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"${out}")
    pub=$(awk -F': *' 'tolower($1) ~ /password|public/ {print $2; exit}' <<<"${out}")
    [[ -n "${priv}" && -n "${pub}" ]] || die "无法解析 xray x25519 的输出"
    printf '%s %s\n' "${priv}" "${pub}"
}

# 每台服务器单独生成 shortId，避免所有服务器共用同一个固定值形成特征
new_short_id() { rand_hex 16; }
new_path() { printf '/%s' "$(rand_alnum 10)"; }

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# 从分享链接里取出 # 后面的节点名称并解码
urldecode_name() {
    local name=${1##*#}
    printf '%b' "${name//%/\\x}"
}

# 节点名称：「用户名_协议名」，用户名是邮箱 @ 前面的部分，多个用户的节点不会混在一起
link_name() {
    local title
    case "$2" in
    Reality) title=Reality-Vision ;;
    Hy2) title=Hysteria2 ;;
    XHTTP) title=XHTTP-TLS ;;
    RealityXHTTP) title=Reality-XHTTP ;;
    Vision) title=TLS-Vision ;;
    *) title=$2 ;;
    esac
    printf '%s_%s' "${1%@*}" "${title}"
}

# 加载协议模块
load_protocols() {
    local f
    for f in "${EZ_HOME}"/protocols/*.sh; do
        # shellcheck source=/dev/null
        source "${f}"
    done
}

# 重新生成协议的密钥：删除 <协议>_secrets 列出的字段，再由 init 重新生成。端口、用户和订阅地址不变
proto_rekey_state() {
    local p=$1 fn f
    fn=$(proto_fn "${p}" secrets)
    declare -F "${fn}" >/dev/null || return 0
    # 从没开启过的协议没有密钥，不用处理
    [[ -n "$(proto_get "${p}" .port)" ]] || return 0
    for f in $("${fn}"); do
        state_update 'del(.protocols[$p][$f])' --arg p "${p}" --arg f "${f}"
    done
    proto_call "${p}" init
}
