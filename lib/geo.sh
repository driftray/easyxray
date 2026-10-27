# shellcheck shell=bash
# geoip / geosite 数据更新：来源与 Xray 官方发布包相同（XTLS/Xray-rules-dat，GeoIP 精简版 + GeoSite 标准版）
# 下载后校验 SHA256，并用当前配置测试新数据，通过才替换；替换后 Xray 启动失败时换回旧数据

EZ_GEO_BASE=${EZ_GEO_BASE:-https://raw.githubusercontent.com/XTLS/Xray-rules-dat/release}
EZ_GEO_TIMER=/etc/systemd/system/easyxray-geo.timer
EZ_GEO_SERVICE=/etc/systemd/system/easyxray-geo.service

geo_dir() { dirname "${EZ_XRAY_BIN}"; }

# 本机 geosite.dat 的更新日期
geo_date() {
    local f
    f="$(geo_dir)/geosite.dat"
    [[ -f "${f}" ]] && date -r "${f}" +%F 2>/dev/null
}

# 下载一个文件并校验：geo_fetch 远程路径 本地文件
geo_fetch() {
    local remote=$1 out=$2 expected actual
    curl -fsSL --retry 2 -m 120 -o "${out}" "${EZ_GEO_BASE}/${remote}" || { err "下载失败：${EZ_GEO_BASE}/${remote}"; return 1; }
    expected=$(curl -fsSL --retry 2 -m 30 "${EZ_GEO_BASE}/${remote}.sha256sum" | awk '{print $1}')
    actual=$(sha256sum "${out}" 2>/dev/null || shasum -a 256 "${out}")
    actual=${actual%% *}
    [[ -n "${expected}" && "${expected}" == "${actual}" ]] || { err "校验失败：${remote}（期望 ${expected:-未知}，实际 ${actual}）"; return 1; }
}

geo_update() {
    local dir tmp f changed=0 out
    dir=$(geo_dir)
    tmp=$(mktemp -d)
    info "下载 geo 数据（XTLS/Xray-rules-dat）..."
    if ! geo_fetch geoip/geoip-lite.dat "${tmp}/geoip.dat" || ! geo_fetch geosite/geosite.dat "${tmp}/geosite.dat"; then
        rm -rf "${tmp}"
        return 1
    fi
    for f in geoip.dat geosite.dat; do
        cmp -s "${tmp}/${f}" "${dir}/${f}" || changed=1
    done
    if ((changed == 0)); then
        rm -rf "${tmp}"
        ok "geo 数据已经是最新"
        return 0
    fi
    # 当前的分流规则可能用到了新数据里已经删除的分类，先测试
    if [[ -d "${EZ_XRAY_CONF}" ]] && ! out=$(XRAY_LOCATION_ASSET="${tmp}" "${EZ_XRAY_BIN}" run -test -confdir "${EZ_XRAY_CONF}" 2>&1); then
        rm -rf "${tmp}"
        err "新数据和当前的分流规则不兼容，没有替换："
        grep -vE '^\s*$' <<<"${out}" | tail -2 | sed 's/^/  /' >&2
        return 1
    fi
    for f in geoip.dat geosite.dat; do
        [[ -f "${dir}/${f}" ]] && cp -p "${dir}/${f}" "${tmp}/${f}.old"
        install -m 644 "${tmp}/${f}" "${dir}/${f}"
    done
    xray_restart
    if ! health_check; then
        for f in geoip.dat geosite.dat; do
            [[ -f "${tmp}/${f}.old" ]] && install -m 644 "${tmp}/${f}.old" "${dir}/${f}"
        done
        xray_restart
        rm -rf "${tmp}"
        err "使用新数据后 Xray 启动失败，已换回原来的数据"
        return 1
    fi
    rm -rf "${tmp}"
    ok "geo 数据已更新"
}

geo_auto_enabled() { [[ -f "${EZ_GEO_TIMER}" ]] && systemctl is-enabled --quiet easyxray-geo.timer 2>/dev/null; }

# 每周自动更新一次（周日凌晨 4 点后随机 1 小时内，错过时开机后补做）
geo_auto_on() {
    no_system && return 0
    cat >"${EZ_GEO_SERVICE}" <<EOF
[Unit]
Description=easyxray geo 数据更新
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${EZ_HOME}/easyxray geo update
EOF
    cat >"${EZ_GEO_TIMER}" <<EOF
[Unit]
Description=每周更新 easyxray 的 geo 数据

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now easyxray-geo.timer >/dev/null 2>&1
}

geo_auto_off() {
    no_system && return 0
    systemctl disable --now easyxray-geo.timer >/dev/null 2>&1
    rm -f "${EZ_GEO_TIMER}" "${EZ_GEO_SERVICE}"
    systemctl daemon-reload
}
