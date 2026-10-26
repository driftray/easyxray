# shellcheck shell=bash
# doctor：一次检查运行状态，每项给出 正常 / 注意 / 有问题

doc_ok() { printf '  %s正常%s   %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
doc_warn() { printf '  %s注意%s   %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
doc_bad() { printf '  %s有问题%s %s\n' "${C_RED}" "${C_RESET}" "$*"; }

ez_doctor() {
    local v p port proto days level size need missing current fresh
    info "服务"
    if systemctl is-active easyxray >/dev/null 2>&1; then doc_ok "Xray 运行中"; else doc_bad "Xray 没有运行（journalctl -u easyxray 查看原因）"; fi
    v=$(xray_installed_version)
    if [[ "${v}" == "${EZ_XRAY_RECOMMENDED}" ]]; then doc_ok "Xray ${v}（推荐版本）"; else doc_warn "Xray ${v:-未安装}，推荐版本是 ${EZ_XRAY_RECOMMENDED}"; fi
    if systemctl is-active nginx >/dev/null 2>&1; then
        doc_ok "Nginx 运行中：$(nginx -v 2>&1 | grep -oE '[0-9.]+$')，$(openssl version | awk '{print $1, $2}')"
    else
        doc_bad "Nginx 没有运行"
    fi

    info "协议端口"
    while read -r p; do
        [[ -z "${p}" ]] && continue
        port=$(proto_get "${p}" .port)
        proto=$(proto_call "${p}" transport)
        if port_in_use "${port}" "${proto}" && [[ "$(port_owner "${port}" "${proto}")" == "xray" ]]; then
            doc_ok "$(proto_call "${p}" title)  ${proto^^} ${port}"
        else
            doc_bad "$(proto_call "${p}" title)  ${proto^^} ${port} 没有被 Xray 监听"
        fi
    done < <(enabled_protocols)
    doc_warn "云服务商的安全组需要放行：$(required_ports | sort -u | tr '\n' ' ')（从服务器内部无法检测）"

    info "系统"
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then doc_ok "BBR 已开启"; else doc_bad "BBR 没有开启（跨境线路上会很慢）"; fi
    need=$(required_ports | sort -u)
    missing=''
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        while read -r p; do ufw status | grep -q "^${p} " || missing+="${p} "; done <<<"${need}"
    elif command -v iptables >/dev/null 2>&1; then
        while IFS=/ read -r port proto; do
            iptables -S INPUT 2>/dev/null | grep -- '--comment easyxray' | grep -q -- "-p ${proto} .*--dport ${port} " || missing+="${port}/${proto} "
        done <<<"${need}"
    fi
    if [[ -z "${missing}" ]]; then doc_ok "系统防火墙已放行所需端口"; else doc_bad "系统防火墙没有放行：${missing}（运行 easyxray apply 修复）"; fi
    if [[ -s "$(cert_file)" ]]; then
        days=$((($(date -d "$(openssl x509 -enddate -noout -in "$(cert_file)" | cut -d= -f2)" +%s) - $(date +%s)) / 86400))
        if ((days > 20)); then doc_ok "证书还有 ${days} 天到期（certbot 会自动续期）"; else doc_warn "证书还有 ${days} 天到期，请检查 certbot 自动续期（systemctl list-timers | grep certbot）"; fi
    else
        doc_bad "没有找到证书 $(cert_file)"
    fi
    level=$(state_get '.system.logLevel')
    if [[ "${level:-warning}" == "debug" ]]; then doc_warn "调试日志开着（easyxray log normal 关闭）"; else doc_ok "日志级别 ${level:-warning}"; fi
    size=$(du -sh "${EZ_LOG}" 2>/dev/null | cut -f1)
    doc_ok "日志目录占用 ${size:-0}"

    info "分流"
    if [[ -n "$(state_get '.outbounds["warp-ipv4"].privateKey')" ]]; then
        doc_ok "WARP 出口已配置（内核 TUN）；规则：$(jq -r '[.routing.rules[]? | select(.outbound == "warp-ipv4") | (.domains + .ips)[]] | join(", ")' "${EZ_STATE}")"
    else
        doc_ok "没有配置 WARP"
    fi
    if [[ "$(state_get '.routing.blockQUIC')" == "true" ]]; then doc_ok "QUIC 屏蔽：开启"; else doc_ok "QUIC 屏蔽：关闭"; fi

    info "配置一致性"
    current="${EZ_XRAY_CONF}/config.json"
    fresh=$(xray_config_json 2>/dev/null)
    if [[ -f "${current}" ]] && [[ "$(jq -S . "${current}")" == "$(jq -S . <<<"${fresh}")" ]]; then
        doc_ok "Xray 配置与状态文件一致"
    else
        doc_warn "Xray 配置和状态文件不一致（可能被手动修改过），运行 easyxray apply 重新生成"
    fi
}
