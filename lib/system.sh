# shellcheck shell=bash
# 系统相关：系统检查、软件包、Xray 安装与校验、systemd 服务、BBR、日志轮转、防火墙、证书

check_os() {
    no_system && return 0
    [[ -r /etc/os-release ]] || die "无法识别系统，只支持 Debian 12+ 和 Ubuntu 22.04+"
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID}" in
    debian) [[ "${VERSION_ID%%.*}" -ge 12 ]] || die "Debian 版本太旧（${VERSION_ID}），需要 12 或更新" ;;
    ubuntu) [[ "${VERSION_ID%%.*}" -ge 22 ]] || die "Ubuntu 版本太旧（${VERSION_ID}），需要 22.04 或更新" ;;
    *) die "不支持的系统：${PRETTY_NAME:-${ID}}，只支持 Debian 12+ 和 Ubuntu 22.04+" ;;
    esac
}

# 旧脚本（v2ray-agent / vasma）还在时不安装，避免端口和证书冲突
check_legacy() {
    no_system && return 0
    if [[ -d /etc/v2ray-agent ]] || systemctl cat xray.service 2>/dev/null | grep -q v2ray-agent; then
        die "检测到旧脚本（/etc/v2ray-agent），请先卸载旧脚本再安装"
    fi
}

install_packages() {
    no_system && return 0
    info "安装软件包..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt-get update 失败"
    # 无域名模式不需要 Nginx 和 certbot
    local pkgs=(curl jq unzip openssl ca-certificates iproute2 logrotate qrencode)
    [[ "${1:-}" == nodomain ]] || pkgs+=(nginx certbot)
    apt-get install -y -qq "${pkgs[@]}" >/dev/null || die "安装软件包失败"
}

ensure_service_user() {
    no_system && return 0
    id "${EZ_USER}" >/dev/null 2>&1 ||
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "${EZ_USER}"
}

xray_arch() {
    case "$(uname -m)" in
    x86_64 | amd64) printf '64' ;;
    aarch64 | arm64) printf 'arm64-v8a' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

# Xray 最新正式版（带 v，不包括预发布版本），获取失败时为空
xray_latest_version() {
    local v
    v=$(latest_release XTLS/Xray-core)
    [[ -n "${v}" ]] && printf 'v%s' "${v}"
}

xray_installed_version() {
    [[ -x "${EZ_XRAY_BIN}" ]] || return 0
    "${EZ_XRAY_BIN}" version 2>/dev/null | awk 'NR==1{print "v"$2}'
}

# 下载指定版本，用官方 .dgst 文件校验 SHA256，校验通过才替换
install_xray() {
    local version=$1 arch tmp url expected actual
    [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式不正确：${version}（例如 v26.10.31）"
    [[ "$(xray_installed_version)" == "${version}" ]] && return 0
    no_system && die "测试模式下请用 EZ_XRAY_BIN 指定 xray"
    arch=$(xray_arch)
    tmp=$(mktemp -d)
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    info "下载 Xray ${version}..."
    curl -fsSL --retry 2 -m 120 -o "${tmp}/xray.zip" "${url}" || { rm -rf "${tmp}"; die "下载失败：${url}"; }
    curl -fsSL --retry 2 -m 30 -o "${tmp}/xray.zip.dgst" "${url}.dgst" || { rm -rf "${tmp}"; die "下载校验文件失败：${url}.dgst"; }
    expected=$(grep -iE '^SHA2?-?256' "${tmp}/xray.zip.dgst" | head -1 | awk -F'= *' '{print tolower($2)}')
    actual=$(sha256sum "${tmp}/xray.zip" | awk '{print $1}')
    if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
        rm -rf "${tmp}"
        die "Xray 文件校验失败（期望 ${expected:-未知}，实际 ${actual}），已停止安装"
    fi
    unzip -qo "${tmp}/xray.zip" xray geoip.dat geosite.dat -d "${tmp}/out" || { rm -rf "${tmp}"; die "解压失败"; }
    # 先试运行一次，架构不对或文件损坏时不替换
    chmod 755 "${tmp}/out/xray"
    "${tmp}/out/xray" version >/dev/null 2>&1 || { rm -rf "${tmp}"; die "下载的 Xray 无法运行（架构不对或文件损坏），没有替换"; }
    mkdir -p "${EZ_HOME}/bin"
    install -m 755 "${tmp}/out/xray" "${EZ_HOME}/bin/xray.new"
    install -m 644 "${tmp}/out/geoip.dat" "${tmp}/out/geosite.dat" "${EZ_HOME}/bin/"
    mv -f "${EZ_HOME}/bin/xray.new" "${EZ_XRAY_BIN}"
    rm -rf "${tmp}"
    ok "Xray ${version} 安装完成（SHA256 校验通过）"
}

install_service() {
    no_system && return 0
    cat >/etc/systemd/system/easyxray.service <<EOF
[Unit]
Description=easyxray (Xray-core)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${EZ_USER}
Group=${EZ_USER}
# 只给两项权限：监听 443 等低端口、创建 WARP 的 TUN 网卡
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
UMask=0077
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${EZ_LOG}
Environment=XRAY_LOCATION_ASSET=${EZ_HOME}/bin
ExecStart=${EZ_XRAY_BIN} run -confdir ${EZ_XRAY_CONF}
Restart=on-failure
RestartSec=3
# 配置无法加载时 Xray 以 23 退出，不再反复重启
RestartPreventExitStatus=23
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable easyxray >/dev/null 2>&1
}

# Nginx 工作进程的用户：系统自带的版本是 www-data，nginx.org 官方源的版本是 nginx
nginx_worker_user() {
    local u
    u=$(awk '/^[[:space:]]*user[[:space:]]/ {gsub(";", "", $2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null)
    printf '%s' "${u:-www-data}"
}

# 配置和证书对服务用户只读；状态文件只有 root 能读
fix_permissions() {
    no_system && return 0
    chown root:"${EZ_USER}" "${EZ_ETC}" "${EZ_XRAY_CONF}" "${EZ_TLS}"
    chmod 750 "${EZ_ETC}" "${EZ_XRAY_CONF}" "${EZ_TLS}"
    chown root:"${EZ_USER}" "${EZ_XRAY_CONF}"/*.json "${EZ_TLS}"/* 2>/dev/null
    chmod 640 "${EZ_XRAY_CONF}"/*.json "${EZ_TLS}"/* 2>/dev/null
    # 校验配置时 xray run -test 会以 root 创建日志文件，这里连文件一起交给服务用户
    chown -R "${EZ_USER}:${EZ_USER}" "${EZ_LOG}"
    chmod 750 "${EZ_LOG}"
    chmod 600 "${EZ_STATE}"
    # Nginx 工作进程需要读取订阅文件
    chown -R root:"$(nginx_worker_user)" "${EZ_SUB}"
    chmod 750 "${EZ_SUB}"
    chmod 640 "${EZ_SUB}"/* 2>/dev/null
    chmod 711 "${EZ_ETC}"
}

xray_restart() {
    no_system && return 0
    systemctl restart easyxray
}

# easyxray 写入的内核参数（BBR、MPTCP）都放在这一个文件里
EZ_SYSCTL_CONF=/etc/sysctl.d/99-easyxray.conf

# 在 EZ_SYSCTL_CONF 里设置或删除一项：sysctl_conf_set 名称 值 / sysctl_conf_del 名称
sysctl_conf_set() {
    sysctl_conf_del "$1"
    printf '%s=%s\n' "$1" "$2" >>"${EZ_SYSCTL_CONF}"
}
sysctl_conf_del() {
    [[ -f "${EZ_SYSCTL_CONF}" ]] || return 0
    local rest
    rest=$(grep -v "^$1=" "${EZ_SYSCTL_CONF}")
    if [[ -n "${rest}" ]]; then printf '%s\n' "${rest}" >"${EZ_SYSCTL_CONF}"; else rm -f "${EZ_SYSCTL_CONF}"; fi
}
sysctl_conf_has() { [[ -f "${EZ_SYSCTL_CONF}" ]] && grep -qx "$1=$2" "${EZ_SYSCTL_CONF}"; }

# 0.5.0 之前 BBR 设置写在 99-easyxray-bbr.conf，合并到新文件；开机加载模块的 easyxray-bbr.conf 不再需要（设置 BBR 时内核会自动加载模块）
migrate_sysctl_conf() {
    no_system && return 0
    local line
    if [[ -f /etc/sysctl.d/99-easyxray-bbr.conf ]]; then
        while IFS= read -r line; do
            [[ "${line}" == *=* ]] && sysctl_conf_set "${line%%=*}" "${line#*=}"
        done </etc/sysctl.d/99-easyxray-bbr.conf
        rm -f /etc/sysctl.d/99-easyxray-bbr.conf
    fi
    rm -f /etc/modules-load.d/easyxray-bbr.conf
}

# 默认路由所在的网卡
default_dev() { ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'; }

# 网卡已经在用的队列不会跟着 default_qdisc 改变，要等重启。这里删掉根队列，内核会按 default_qdisc 重新挂上默认队列：
# 多队列网卡是 mq，子队列为 fq；单队列网卡直接是 fq。
# 只替换系统默认的队列（mq / fq_codel / pfifo_fast），用户自己配置的整形（htb、cake 等）不动
apply_fq_qdisc() {
    no_system && return 0
    [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]] || return 0
    local dev root
    dev=$(default_dev)
    [[ -n "${dev}" ]] || return 0
    root=$(tc qdisc show dev "${dev}" root 2>/dev/null | awk '{print $2; exit}')
    case "${root}" in
    mq) tc qdisc show dev "${dev}" | grep -qv -e '^qdisc mq ' -e '^qdisc fq ' || return 0 ;;
    fq) return 0 ;;
    fq_codel | pfifo_fast) ;;
    *) return 0 ;;
    esac
    tc qdisc del dev "${dev}" root 2>/dev/null
    qdisc_is_fq || tc qdisc replace dev "${dev}" root fq 2>/dev/null
    if qdisc_is_fq; then ok "网卡 ${dev} 的队列已换成 fq"; else warn "网卡 ${dev} 的队列没能换成 fq，重启后生效"; fi
}

# 网卡在用的队列是不是 fq（多队列时每个子队列都是 fq）
qdisc_is_fq() {
    local dev
    dev=$(default_dev)
    [[ -n "${dev}" ]] || return 0
    ! tc qdisc show dev "${dev}" 2>/dev/null | grep -qv -e '^qdisc mq ' -e '^qdisc fq '
}

enable_bbr() {
    no_system && return 0
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        apply_fq_qdisc
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || {
        warn "内核不支持 BBR，跳过"
        return 0
    }
    sysctl_conf_set net.core.default_qdisc fq
    sysctl_conf_set net.ipv4.tcp_congestion_control bbr
    sysctl --system >/dev/null 2>&1
    ok "已开启 BBR"
    apply_fq_qdisc
}

# 已安装的 Xray 低于最低安全版本
xray_too_old() {
    local v
    v=$(xray_installed_version)
    [[ -n "${v}" ]] && version_newer "${EZ_XRAY_MIN#v}" "${v#v}"
}

# 用户自己写过 net.mptcp.enabled 的配置文件（不含 easyxray 的），没有时为空
mptcp_user_conf() {
    grep -lsE '^[[:space:]]*net[./]mptcp[./]enabled[[:space:]]*=' /etc/sysctl.conf /etc/sysctl.d/*.conf |
        grep -vx "${EZ_SYSCTL_CONF}" | head -n 1
}

# 用户用 ezx mptcp on 保持开启
mptcp_allowed() { state_exists && [[ "$(state_get '.system.mptcpAllowed')" == "true" ]]; }

# 关闭 MPTCP：代理服务器用不到，关闭后宿主机上的程序都无法通过 MPTCP 监听（Docker 容器有自己的网络命名空间，不受影响）
# 用户用 ezx mptcp on 开启过，或自己设置过 net.mptcp.enabled 时不修改
disable_mptcp() {
    no_system && return 0
    [[ -e /proc/sys/net/mptcp/enabled ]] || return 0
    mptcp_allowed && return 0
    local conf
    conf=$(mptcp_user_conf)
    if [[ -n "${conf}" ]]; then
        [[ "$(sysctl -n net.mptcp.enabled)" == "0" ]] || warn "${conf} 里设置了 net.mptcp.enabled，easyxray 不修改 MPTCP"
        return 0
    fi
    [[ "$(sysctl -n net.mptcp.enabled)" == "0" ]] && sysctl_conf_has net.mptcp.enabled 0 && return 0
    sysctl_conf_set net.mptcp.enabled 0
    sysctl -q -w net.mptcp.enabled=0
    ok "已关闭 MPTCP"
}

# 删除 easyxray 的 MPTCP 设置，恢复系统默认（开启）
restore_mptcp() {
    no_system && return 0
    sysctl_conf_has net.mptcp.enabled 0 || return 0
    sysctl_conf_del net.mptcp.enabled
    [[ -n "$(mptcp_user_conf)" ]] || sysctl -q -w net.mptcp.enabled=1 2>/dev/null
    return 0
}

# 安全基线：关闭 MPTCP，Xray 低于最低安全版本时升级到最新正式版。安装和 apply（ezx update 会调用）时执行
ensure_security() {
    no_system && return 0
    local v
    migrate_sysctl_conf
    apply_fq_qdisc
    disable_mptcp
    xray_too_old || return 0
    v=$(xray_latest_version)
    if [[ -z "${v}" ]]; then
        warn "Xray $(xray_installed_version) 低于安全版本 ${EZ_XRAY_MIN}，但无法获取最新版本，请稍后运行 ezx xray use"
        return 0
    fi
    warn "Xray $(xray_installed_version) 低于安全版本 ${EZ_XRAY_MIN}，升级到 ${v}"
    (install_xray "${v}") && state_update '.xray.version = $v' --arg v "${v}"
}

install_logrotate() {
    no_system && return 0
    cat >/etc/logrotate.d/easyxray <<EOF
${EZ_LOG}/*.log {
    weekly
    rotate 4
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

# ---------- 防火墙：按需要的端口同步，规则带 easyxray 标记，多余的自动删除 ----------

# 输出需要放行的端口：每行 "端口/协议"。80 端口用于申请证书，无域名模式不需要
required_ports() {
    no_domain || printf '80/tcp\n'
    local p
    while read -r p; do
        [[ -z "${p}" ]] && continue
        printf '%s/%s\n' "$(proto_get "${p}" .port)" "$(proto_call "${p}" transport)"
    done < <(enabled_protocols)
}

# 云服务商安全组需要放行的端口：除了 required_ports，还有端口跳跃的范围
# （跳跃范围的数据包在进入系统防火墙之前已经转发到监听端口，系统防火墙只需要放行监听端口）
cloud_ports() {
    required_ports
    local range
    range=$(hop_range)
    [[ -n "${range}" ]] && printf '%s/udp\n' "${range}"
    return 0
}

sync_firewall() {
    sync_hop
    no_system && return 0
    local need port proto rule
    need=$(required_ports | sort -u)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        while read -r rule; do ufw allow "${rule}" comment easyxray >/dev/null; done <<<"${need}"
        ufw status | awk '/easyxray/ {print $1}' | sort -u | while read -r rule; do
            grep -qx "${rule}" <<<"${need}" || ufw delete allow "${rule}" >/dev/null
        done
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        while read -r rule; do firewall-cmd --permanent --add-port="${rule}" >/dev/null; done <<<"${need}"
        firewall-cmd --reload >/dev/null
    elif command -v iptables >/dev/null 2>&1; then
        # 甲骨文等镜像的 INPUT 链最后有拒绝规则，需要在前面插入放行规则
        local cmd
        for cmd in iptables ip6tables; do
            command -v "${cmd}" >/dev/null 2>&1 || continue
            "${cmd}" -S INPUT 2>/dev/null | grep -- '--comment easyxray' | sed 's/^-A /-D /' | while read -r rule; do
                # shellcheck disable=SC2086
                "${cmd}" ${rule} 2>/dev/null
            done
            while IFS=/ read -r port proto; do
                "${cmd}" -I INPUT -p "${proto}" --dport "${port}" -m comment --comment easyxray -j ACCEPT
            done <<<"${need}"
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi
}

# ---------- Hysteria2 端口跳跃：nftables 把范围内的 UDP 端口转发到监听端口 ----------
# 规则放在单独的 inet easyxray_hop 表里，不影响系统的其他规则；开机由 easyxray-hop.service 重新加载

EZ_HOP_NFT=${EZ_ETC}/hop.nft
EZ_HOP_UNIT=/etc/systemd/system/easyxray-hop.service

# 正在使用的跳跃范围：Hysteria2 开启且设置了范围时才有
hop_range() {
    protocol_enabled hysteria2 || return 0
    proto_get hysteria2 .hopPorts
}

hop_rules() {
    cat <<EOF
# 由 easyxray 生成：Hysteria2 端口跳跃
table inet easyxray_hop
delete table inet easyxray_hop
table inet easyxray_hop {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport $1 redirect to :$2
    }
}
EOF
}

hop_remove() {
    rm -f "${EZ_HOP_NFT}"
    no_system && return 0
    if [[ -f "${EZ_HOP_UNIT}" ]]; then
        systemctl disable --now easyxray-hop >/dev/null 2>&1
        rm -f "${EZ_HOP_UNIT}"
        systemctl daemon-reload
    fi
    if command -v nft >/dev/null 2>&1 && nft list table inet easyxray_hop >/dev/null 2>&1; then
        nft delete table inet easyxray_hop
    fi
}

sync_hop() {
    local range nft
    range=$(hop_range)
    if [[ -z "${range}" ]]; then
        hop_remove
        return 0
    fi
    hop_rules "${range}" "$(proto_get hysteria2 .port)" >"${EZ_HOP_NFT}"
    no_system && return 0
    if ! command -v nft >/dev/null 2>&1; then
        info "安装 nftables（端口跳跃需要）..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables </dev/null >/dev/null 2>&1 ||
            { err "安装 nftables 失败，端口跳跃没有生效"; return 1; }
    fi
    nft=$(command -v nft)
    "${nft}" -c -f "${EZ_HOP_NFT}" || { err "端口跳跃规则有误，没有加载"; return 1; }
    cat >"${EZ_HOP_UNIT}" <<EOF
[Unit]
Description=easyxray Hysteria2 port hopping
After=network-pre.target
Before=easyxray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft} -f ${EZ_HOP_NFT}
ExecStop=${nft} delete table inet easyxray_hop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable easyxray-hop >/dev/null 2>&1
    # 由服务加载规则：开机时也是同一个服务加载，状态一致
    systemctl restart easyxray-hop || { err "加载端口跳跃规则失败（journalctl -u easyxray-hop 查看原因）"; return 1; }
}

hop_active() { command -v nft >/dev/null 2>&1 && nft list table inet easyxray_hop >/dev/null 2>&1; }

remove_firewall_rules() {
    hop_remove
    no_system && return 0
    local rule cmd
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw status | awk '/easyxray/ {print $1}' | sort -u | while read -r rule; do ufw delete allow "${rule}" >/dev/null; done
    fi
    for cmd in iptables ip6tables; do
        command -v "${cmd}" >/dev/null 2>&1 || continue
        "${cmd}" -S INPUT 2>/dev/null | grep -- '--comment easyxray' | sed 's/^-A /-D /' | while read -r rule; do
            # shellcheck disable=SC2086
            "${cmd}" ${rule} 2>/dev/null
        done
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    return 0
}

# ---------- 证书：系统软件源里的 certbot，HTTP-01 验证（需要 80 端口） ----------

install_cert_hook() {
    no_system && return 0
    local domain
    domain=$(state_get .domain)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/easyxray.sh <<EOF
#!/bin/bash
# 证书续期后复制给 easyxray，并重新加载 Xray 和 Nginx
[[ "\${RENEWED_LINEAGE}" == */${domain} ]] || exit 0
install -m 640 -o root -g ${EZ_USER} "\${RENEWED_LINEAGE}/fullchain.pem" "${EZ_TLS}/${domain}.crt"
install -m 640 -o root -g ${EZ_USER} "\${RENEWED_LINEAGE}/privkey.pem" "${EZ_TLS}/${domain}.key"
systemctl restart easyxray
systemctl reload nginx
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/easyxray.sh
}

issue_cert() {
    no_system && return 0
    local domain live
    domain=$(state_get .domain)
    live=/etc/letsencrypt/live/${domain}
    mkdir -p "${EZ_TLS}"
    if [[ ! -s "${live}/fullchain.pem" ]]; then
        info "申请证书（Let's Encrypt，HTTP 验证，需要 80 端口能从外网访问）..."
        certbot certonly --webroot -w "${EZ_WWW}/acme" -d "${domain}" \
            --non-interactive --agree-tos --register-unsafely-without-email --key-type ecdsa ||
            die "证书申请失败。请检查：域名 ${domain} 是否解析到本机、云安全组是否放行 TCP 80"
    fi
    install -m 640 -o root -g "${EZ_USER}" "${live}/fullchain.pem" "${EZ_TLS}/${domain}.crt"
    install -m 640 -o root -g "${EZ_USER}" "${live}/privkey.pem" "${EZ_TLS}/${domain}.key"
    install_cert_hook
}

public_ipv4() { curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null; }

# 域名是否解析到本机，不一致时只提示，不阻止安装
check_dns() {
    no_system && return 0
    local domain ip resolved
    domain=$(state_get .domain)
    ip=$(public_ipv4)
    resolved=$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [[ -n "${ip}" && " ${resolved} " != *" ${ip} "* ]]; then
        warn "域名 ${domain} 解析到 [${resolved:-无}]，本机公网 IP 是 ${ip}，两者不一致，证书可能申请失败"
    fi
}
