# shellcheck shell=bash
# 更新 easyxray 自身：从 GitHub Release 下载固定文件名的压缩包，校验 SHA256 后替换程序文件
#
# 测试时可以设置 EZ_RELEASE_BASE 为本地目录（file:///path），代替 Release 下载地址

# 最新发布的版本号（不带 v）：读 releases/latest 的跳转地址，不调用 GitHub API，避免频率限制
# releases/latest 不包括预发布版本。参数为仓库，默认是 easyxray
latest_release() {
    curl -fsSI -o /dev/null -w '%{redirect_url}' --max-time 15 "https://github.com/${1:-${EZ_REPO}}/releases/latest" |
        sed -n 's#.*/tag/v\{0,1\}##p'
}

# a 比 b 新时返回 0
version_newer() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

sha256_check() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --status "$1"; else shasum -a 256 -c --status "$1"; fi
}

# 用 EZ_HOME 下的文件替换 EZ_HOME 下除 bin/ 以外的内容（git clone 安装留下的 .git 也一并删除）
replace_program_files() {
    local from=$1
    find "${EZ_HOME}" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
    cp -a "${from}/." "${EZ_HOME}/"
}

# 更新到最新版本，或指定版本：ez_update [版本]
ez_update() {
    local version=${1:-} tmp base
    require_cmd curl tar
    version=${version#v}
    if [[ -z "${version}" ]]; then
        version=$(latest_release)
        [[ -n "${version}" ]] || die "无法获取最新版本，请检查服务器能否访问 github.com"
        if [[ "${version}" == "${EZ_VERSION}" ]]; then
            ok "已经是最新版本 ${EZ_VERSION}"
            return 0
        fi
        if version_newer "${EZ_VERSION}" "${version}"; then
            ok "当前版本 ${EZ_VERSION} 比最新发布的 ${version} 还新，不需要更新"
            return 0
        fi
    fi
    # EZ_HOME 判断错时 replace_program_files 会删错目录，先确认它确实是 easyxray 程序目录
    [[ "${EZ_HOME}" != "/" && -f "${EZ_HOME}/easyxray" && -f "${EZ_HOME}/lib/common.sh" ]] ||
        die "程序目录不正确：${EZ_HOME}"

    info "更新 easyxray：${EZ_VERSION} → ${version}"
    tmp=$(mktemp -d)
    base=${EZ_RELEASE_BASE:-https://github.com/${EZ_REPO}/releases/download/v${version}}
    if ! curl -fsSL --retry 2 -o "${tmp}/easyxray.tar.gz" "${base}/easyxray.tar.gz" ||
        ! curl -fsSL --retry 2 -o "${tmp}/easyxray.tar.gz.sha256" "${base}/easyxray.tar.gz.sha256"; then
        rm -rf "${tmp}"
        die "下载失败：${base}/easyxray.tar.gz"
    fi
    if ! (cd "${tmp}" && sha256_check easyxray.tar.gz.sha256); then
        rm -rf "${tmp}"
        die "SHA256 校验失败，没有做任何修改"
    fi
    mkdir "${tmp}/new" "${tmp}/old"
    if ! tar -xzf "${tmp}/easyxray.tar.gz" -C "${tmp}/new" --no-same-owner ||
        ! bash "${tmp}/new/easyxray" help >/dev/null 2>&1; then
        rm -rf "${tmp}"
        die "压缩包内容不正确，没有做任何修改"
    fi

    # 先备份旧程序；新程序生成的配置无法通过校验时换回旧程序
    cp -a "${EZ_HOME}/." "${tmp}/old/"
    rm -rf "${tmp}/old/bin"
    replace_program_files "${tmp}/new"
    if state_exists && ! "${EZ_HOME}/easyxray" apply; then
        replace_program_files "${tmp}/old"
        rm -rf "${tmp}"
        "${EZ_HOME}/easyxray" apply >/dev/null 2>&1
        die "新版本生成的配置没有通过校验，已换回 ${EZ_VERSION}"
    fi
    rm -rf "${tmp}"
    ok "已更新到 easyxray ${version}"
}
