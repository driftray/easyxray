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
    apt-get install -y -qq curl jq unzip openssl ca-certificates iproute2 nginx certbot logrotate qrencode >/dev/null ||
        die "安装软件包失败"
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
    curl -fsSL -m 120 -o "${tmp}/xray.zip" "${url}" || { rm -rf "${tmp}"; die "下载失败：${url}"; }
    curl -fsSL -m 30 -o "${tmp}/xray.zip.dgst" "${url}.dgst" || { rm -rf "${tmp}"; die "下载校验文件失败：${url}.dgst"; }
    expected=$(grep -iE '^SHA2?-?256' "${tmp}/xray.zip.dgst" | head -1 | awk -F'= *' '{print tolower($2)}')
    actual=$(sha256sum "${tmp}/xray.zip" | awk '{print $1}')
    if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
        rm -rf "${tmp}"
        die "Xray 文件校验失败（期望 ${expected:-未知}，实际 ${actual}），已停止安装"
    fi
    unzip -qo "${tmp}/xray.zip" xray geoip.dat geosite.dat -d "${tmp}/out" || { rm -rf "${tmp}"; die "解压失败"; }
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
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${EZ_LOG}
Environment=XRAY_LOCATION_ASSET=${EZ_HOME}/bin
ExecStart=${EZ_XRAY_BIN} run -confdir ${EZ_XRAY_CONF}
Restart=on-failure
RestartSec=3
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

# 0.5.0 之前 BBR 设置写在 99-easyxray-bbr.conf 和 easyxray-bbr.conf，合并到新文件名
migrate_sysctl_conf() {
    no_system && return 0
    local line
    if [[ -f /etc/sysctl.d/99-easyxray-bbr.conf ]]; then
        while IFS= read -r line; do
            [[ "${line}" == *=* ]] && sysctl_conf_set "${line%%=*}" "${line#*=}"
        done </etc/sysctl.d/99-easyxray-bbr.conf
        rm -f /etc/sysctl.d/99-easyxray-bbr.conf
    fi
    [[ -f /etc/modules-load.d/easyxray-bbr.conf ]] && mv -f /etc/modules-load.d/easyxray-bbr.conf /etc/modules-load.d/easyxray.conf
    return 0
}

enable_bbr() {
    no_system && return 0
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] && return 0
    modprobe tcp_bbr 2>/dev/null
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || {
        warn "内核不支持 BBR，跳过"
        return 0
    }
    echo tcp_bbr >/etc/modules-load.d/easyxray.conf
    sysctl_conf_set net.core.default_qdisc fq
    sysctl_conf_set net.ipv4.tcp_congestion_control bbr
    sysctl --system >/dev/null 2>&1
    ok "已开启 BBR"
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

# 输出需要放行的端口：每行 "端口/协议"
required_ports() {
    printf '80/tcp\n'
    local p
    while read -r p; do
        [[ -z "${p}" ]] && continue
        printf '%s/%s\n' "$(proto_get "${p}" .port)" "$(proto_call "${p}" transport)"
    done < <(enabled_protocols)
}

sync_firewall() {
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

remove_firewall_rules() {
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
