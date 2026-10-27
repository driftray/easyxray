# shellcheck shell=bash
# 备份与恢复：备份文件包含状态文件（用户、密钥、端口、分流规则）和伪装站点，不含证书（新服务器上重新申请）
# 恢复只能在没有安装过的服务器上进行，恢复后沿用原来的用户、密钥和端口，客户端不需要重新导入订阅

ez_backup() {
    local out=${1:-} tmp
    state_exists || die "没有可以备份的配置"
    out=${out:-${EZ_ROOT}/root/easyxray-backup-$(date +%Y%m%d-%H%M%S).tar.gz}
    tmp=$(mktemp -d)
    cp -p "${EZ_STATE}" "${tmp}/state.json"
    [[ -d "${EZ_WWW}/site" ]] && cp -rp "${EZ_WWW}/site" "${tmp}/site"
    printf '%s\n' "${EZ_VERSION}" >"${tmp}/version"
    mkdir -p "$(dirname "${out}")"
    (umask 077 && tar -czf "${out}" -C "${tmp}" .) || { rm -rf "${tmp}"; die "备份失败：${out}"; }
    rm -rf "${tmp}"
    chmod 600 "${out}"
    ok "已备份到 ${out}"
    warn "备份文件里有全部用户和密钥，请妥善保管，不要发给别人或上传到网盘、聊天工具"
}

# 把备份文件里的配置放到 /etc/easyxray，标记为未安装；之后由 install 沿用这份配置完成安装
restore_state() {
    local file=$1 tmp
    [[ -f "${file}" ]] || die "找不到备份文件：${file}"
    state_exists && die "这台服务器上已经有 easyxray 的配置。恢复只能在全新的服务器上进行，或先运行 easyxray uninstall --purge"
    tmp=$(mktemp -d)
    tar -xzf "${file}" -C "${tmp}" --no-same-owner 2>/dev/null || { rm -rf "${tmp}"; die "备份文件损坏或格式不正确：${file}"; }
    if ! jq -e '.domain and (.users | length > 0) and .protocols' "${tmp}/state.json" >/dev/null 2>&1; then
        rm -rf "${tmp}"
        die "备份文件里没有有效的配置：${file}"
    fi
    mkdir -p "${EZ_ETC}"
    chmod 711 "${EZ_ETC}"
    jq '.system.installed = false' "${tmp}/state.json" >"${EZ_STATE}"
    chmod 600 "${EZ_STATE}"
    if [[ -d "${tmp}/site" ]]; then
        mkdir -p "${EZ_WWW}"
        rm -rf "${EZ_WWW}/site"
        cp -rp "${tmp}/site" "${EZ_WWW}/site"
    fi
    rm -rf "${tmp}"
    info "已读取备份：域名 $(state_get .domain)，$(jq '.users | length' "${EZ_STATE}") 个用户"
    info "请确认域名已经解析到这台服务器，否则无法申请证书"
}
