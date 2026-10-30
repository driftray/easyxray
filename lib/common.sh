# shellcheck shell=bash
# 公共函数：路径、输出、状态文件读写、随机数
#
# 测试时可以设置：
#   EZ_ROOT        所有系统路径的前缀（例如一个临时目录）
#   EZ_NO_SYSTEM=1 跳过 systemctl、apt、防火墙、证书申请等系统操作
#   EZ_XRAY_BIN    使用指定的 xray 程序

EZ_ROOT=${EZ_ROOT:-}
EZ_HOME=${EZ_HOME:-${EZ_ROOT}/opt/easyxray}
EZ_ETC=${EZ_ROOT}/etc/easyxray
EZ_STATE=${EZ_ETC}/state.json
EZ_XRAY_CONF=${EZ_ETC}/xray
EZ_TLS=${EZ_ETC}/tls
EZ_SUB=${EZ_ETC}/subscribe
EZ_WWW=${EZ_ETC}/www
EZ_LOG=${EZ_ETC}/log
EZ_SNAPSHOTS=${EZ_ETC}/snapshots
EZ_XRAY_BIN=${EZ_XRAY_BIN:-${EZ_HOME}/bin/xray}
EZ_NGINX_CONF=${EZ_ROOT}/etc/nginx/conf.d/easyxray.conf
EZ_USER=easyxray

# easyxray 自身的版本
EZ_VERSION=0.4.0
# 发布地址：更新时从这个仓库的 GitHub Release 下载
EZ_REPO=driftray/easyxray

# 推荐的 Xray 版本：26.10.21 起 Reality 不接受旧版 TLS 指纹，订阅链接因此不带 fp
EZ_XRAY_RECOMMENDED=v26.10.29
# 除 Reality-Vision（固定 443）外，其他协议在这个范围里随机选空闲端口
EZ_PORT_RANGE_DEFAULT=8000-8100
# 本机 Nginx：Reality 回落站点（TLS）和 VLESS-TLS-Vision 回落站点（明文），只监听 127.0.0.1
EZ_REALITY_TARGET_PORT=31305
EZ_VISION_FALLBACK_PORT=31306
# VLESS-TLS-Vision 协商出 h2 时的回落站点（明文 HTTP/2）
EZ_VISION_H2_FALLBACK_PORT=31308
# XHTTP-TLS 由 Nginx 对外监听，再用 grpc_pass 转给 Xray 的这个本机端口
EZ_XHTTP_BACKEND_PORT=31307

if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[36m' C_RESET=$'\e[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

info() { printf '%s\n' "${C_BLUE}$*${C_RESET}"; }
ok() { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_RESET}" >&2; }
err() { printf '%s\n' "${C_RED}$*${C_RESET}" >&2; }
die() {
    err "$*"
    exit 1
}

no_system() { [[ "${EZ_NO_SYSTEM:-}" == "1" ]]; }

require_root() {
    no_system && return 0
    [[ "$(id -u)" == "0" ]] || die "请用 root 运行：sudo ezx ${EZ_CMD:-}（或先 sudo -i 切换到 root）"
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}"
    done
}

# 随机小写字母和数字，$1 为长度
rand_alnum() {
    local length=$1 out=''
    while ((${#out} < length)); do
        out+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9')
    done
    printf '%s' "${out:0:length}"
}

rand_hex() {
    local length=$1
    head -c $(((length + 1) / 2)) /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"${length}"
}

new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        "${EZ_XRAY_BIN}" uuid
    fi
}

# ---------- 状态文件 ----------

state_exists() { [[ -f "${EZ_STATE}" ]]; }

# 读取状态：state_get '.domain'
state_get() {
    jq -r "$1 // empty" "${EZ_STATE}"
}

# 修改状态：state_update 'jq 表达式' [--arg k v ...]
# 先写临时文件再改名，避免中途失败留下半截文件
state_update() {
    local filter=$1
    shift
    local tmp
    tmp=$(mktemp "${EZ_STATE}.XXXXXX")
    if jq "$@" "${filter}" "${EZ_STATE}" >"${tmp}" && [[ -s "${tmp}" ]]; then
        chmod 600 "${tmp}"
        mv -f "${tmp}" "${EZ_STATE}"
    else
        rm -f "${tmp}"
        die "修改状态文件失败：${filter}"
    fi
}

state_init() {
    local domain=$1
    mkdir -p "${EZ_ETC}"
    # 711：Nginx 需要穿过这个目录读取伪装站和订阅文件；状态文件本身是 600
    chmod 711 "${EZ_ETC}"
    jq -n --arg domain "${domain}" --arg xray "${EZ_XRAY_RECOMMENDED}" --arg range "${EZ_PORT_RANGE_DEFAULT}" '{
        version: 1,
        domain: $domain,
        xray: {version: $xray},
        portRange: $range,
        users: [],
        protocols: {},
        routing: {blockQUIC: false, blockBT: true, rules: []},
        outbounds: {},
        system: {}
    }' >"${EZ_STATE}"
    chmod 600 "${EZ_STATE}"
}

protocol_enabled() {
    [[ "$(jq -r --arg p "$1" '.protocols[$p].enabled // false' "${EZ_STATE}")" == "true" ]]
}

# 所有已启用的协议（按固定顺序）
enabled_protocols() {
    local p
    for p in "${EZ_PROTOCOLS[@]}"; do
        protocol_enabled "${p}" && printf '%s\n' "${p}"
    done
}
