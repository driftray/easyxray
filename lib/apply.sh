# shellcheck shell=bash
# apply：根据状态文件整体生成配置 → 校验 → 保存快照 → 替换 → 重启 → 健康检查，任何一步失败都恢复上一份配置

EZ_SNAPSHOT_KEEP=5

xray_test_dir() {
    XRAY_LOCATION_ASSET="$(dirname "${EZ_XRAY_BIN}")" "${EZ_XRAY_BIN}" run -test -confdir "$1" 2>&1
}

# 保存当前生效的状态和配置，返回快照目录
snapshot_save() {
    local dir
    dir="${EZ_SNAPSHOTS}/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "${dir}"
    [[ -f "${EZ_STATE}" ]] && cp -p "${EZ_STATE}" "${dir}/state.json"
    [[ -d "${EZ_XRAY_CONF}" ]] && cp -rp "${EZ_XRAY_CONF}" "${dir}/xray"
    [[ -d "${EZ_SUB}" ]] && cp -rp "${EZ_SUB}" "${dir}/subscribe"
    [[ -f "${EZ_NGINX_CONF}" ]] && cp -p "${EZ_NGINX_CONF}" "${dir}/nginx.conf"
    chmod 700 "${dir}"
    printf '%s' "${dir}"
}

snapshot_prune() {
    local old
    # 只保留最近几份
    while read -r old; do
        rm -rf "${old}"
    done < <(find "${EZ_SNAPSHOTS}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | tail -n +$((EZ_SNAPSHOT_KEEP + 1)))
}

# 把快照里的配置放回去（不重启）
snapshot_restore_files() {
    local dir=$1
    [[ -f "${dir}/state.json" ]] && cp -p "${dir}/state.json" "${EZ_STATE}"
    rm -rf "${EZ_XRAY_CONF}" "${EZ_SUB}"
    [[ -d "${dir}/xray" ]] && cp -rp "${dir}/xray" "${EZ_XRAY_CONF}"
    [[ -d "${dir}/subscribe" ]] && cp -rp "${dir}/subscribe" "${EZ_SUB}"
    if [[ -f "${dir}/nginx.conf" ]]; then
        cp -p "${dir}/nginx.conf" "${EZ_NGINX_CONF}"
    else
        rm -f "${EZ_NGINX_CONF}"
    fi
}

# 每个已启用协议的端口都在监听（TCP/UDP 分开），Xray 在运行
health_check() {
    no_system && return 0
    local p port proto tries
    for ((tries = 0; tries < 10; tries++)); do
        systemctl is-active easyxray >/dev/null 2>&1 && break
        sleep 1
    done
    systemctl is-active easyxray >/dev/null 2>&1 || {
        err "Xray 没有正常启动："
        journalctl -u easyxray -n 5 --no-pager 2>/dev/null | sed 's/^/  /' >&2
        return 1
    }
    sleep 1
    while read -r p; do
        [[ -z "${p}" ]] && continue
        port=$(proto_get "${p}" .port)
        proto=$(proto_call "${p}" transport)
        port_in_use "${port}" "${proto}" || {
            err "$(proto_call "${p}" title) 没有在监听 ${proto^^} ${port}"
            return 1
        }
    done < <(enabled_protocols)
    return 0
}

ez_apply() {
    local tmp out snapshot
    tmp=$(mktemp -d)
    mkdir -p "${tmp}/xray" "${tmp}/subscribe" "${EZ_LOG}" "${EZ_SNAPSHOTS}"

    xray_config_json >"${tmp}/xray/config.json" || { rm -rf "${tmp}"; die "生成 Xray 配置失败"; }
    render_subscriptions "${tmp}/subscribe"
    render_nginx_conf >"${tmp}/nginx.conf"

    if ! out=$(xray_test_dir "${tmp}/xray"); then
        err "Xray 配置校验失败，没有做任何修改："
        grep -vE '^\s*$' <<<"${out}" | tail -3 | sed 's/^/  /' >&2
        rm -rf "${tmp}"
        return 1
    fi

    snapshot=$(snapshot_save)
    rm -rf "${EZ_XRAY_CONF}" "${EZ_SUB}"
    mv "${tmp}/xray" "${EZ_XRAY_CONF}"
    mv "${tmp}/subscribe" "${EZ_SUB}"
    mkdir -p "$(dirname "${EZ_NGINX_CONF}")"
    cp "${tmp}/nginx.conf" "${EZ_NGINX_CONF}"
    rm -rf "${tmp}"
    fix_permissions

    if ! nginx_test; then
        err "Nginx 配置校验失败，已恢复上一份配置"
        snapshot_restore_files "${snapshot}"
        return 1
    fi

    xray_restart
    nginx_reload
    sync_firewall
    if ! health_check; then
        err "新配置启动失败，正在恢复上一份配置..."
        snapshot_restore_files "${snapshot}"
        fix_permissions
        xray_restart
        nginx_reload
        sync_firewall
        return 1
    fi
    snapshot_prune
    return 0
}

# 修改状态并 apply；失败时状态文件也恢复。用法：apply_change 函数名 [参数...]
apply_change() {
    local backup
    backup=$(mktemp "${EZ_STATE}.bak.XXXXXX")
    cp -p "${EZ_STATE}" "${backup}"
    if ("$@") && ez_apply; then
        rm -f "${backup}"
        return 0
    fi
    mv -f "${backup}" "${EZ_STATE}"
    err "修改没有生效，已保持原来的设置"
    return 1
}

# 回到上一份快照
ez_rollback() {
    local last
    last=$(find "${EZ_SNAPSHOTS}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -1)
    [[ -n "${last}" ]] || die "没有可以恢复的快照"
    info "恢复到快照：$(basename "${last}")"
    snapshot_restore_files "${last}"
    fix_permissions
    xray_restart
    nginx_reload
    sync_firewall
    rm -rf "${last}"
    health_check && ok "已恢复"
}
