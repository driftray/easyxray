#!/usr/bin/env bash
# easyxray 安装入口：每次下载并运行这个脚本即可
#   没有安装时：检查环境，下载最新版本并校验 SHA256，解压到 /opt/easyxray，然后安装
#   已经安装时：进入管理菜单（有新版本时提示）
#
# 交互式安装（询问域名和安装方式）：
#   wget -N https://raw.githubusercontent.com/driftray/easyxray/main/install.sh && bash install.sh
# 非交互式安装（全程不提问）：
#   bash install.sh --domain box.example.com [--full] [--protocols a,b] [--port-range 8000-8100] [--email 邮箱]
#   curl -fsSL https://raw.githubusercontent.com/driftray/easyxray/main/install.sh | bash -s -- --domain box.example.com
# 安装指定版本：加上 --version v0.2.0
# SPDX-License-Identifier: GPL-3.0
set -o pipefail

REPO=driftray/easyxray
HOME_DIR=/opt/easyxray
STATE=/etc/easyxray/state.json

if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
    C_RED='' C_GREEN='' C_DIM='' C_RESET=''
fi
pass() { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
fail() { printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*"; FAILED=1; }
die() { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; exit 1; }

version=''
args=()
while (($#)); do
    case "$1" in
    --version) version=${2#v}; shift ;;
    -h | --help) sed -n '2,11p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$1") ;;
    esac
    shift
done

installed() { [[ -f "${STATE}" ]] && grep -q '"installed": *true' "${STATE}"; }
# 保留配置卸载后留下的配置（installed=false），重新安装会沿用
kept_config() { [[ -f "${STATE}" ]] && ! installed; }
interactive() { [[ -t 0 ]]; }

# 最新发布的版本号（不带 v）：读 releases/latest 的跳转地址，不调用 GitHub API
latest_release() {
    curl -fsSI -o /dev/null -w '%{redirect_url}' --max-time 10 "https://github.com/${REPO}/releases/latest" 2>/dev/null |
        sed -n 's#.*/tag/v\{0,1\}##p'
}

# 不是 root 时后面的检查不准确（读不到状态文件和端口占用程序），直接停止
[[ "$(id -u)" == "0" ]] || die "需要 root 权限：请先运行 sudo -i 切换到 root，再运行 bash install.sh"

# ---------- 已经安装：进入菜单 ----------

if installed && [[ -x "${HOME_DIR}/easyxray" ]]; then
    if ((${#args[@]} > 0)); then
        printf 'easyxray 已经安装，不再重复安装。管理请运行 ezx，查看命令：ezx help\n'
        exit 0
    fi
    current=$(sed -n 's/^EZ_VERSION=//p' "${HOME_DIR}/lib/common.sh")
    latest=$(command -v curl >/dev/null 2>&1 && latest_release)
    if [[ -n "${latest}" && "${latest}" != "${current}" &&
        "$(printf '%s\n%s\n' "${latest}" "${current}" | sort -V | tail -n 1)" == "${latest}" ]]; then
        printf '%s发现新版本 %s（当前 %s），可以在菜单「6 版本更新」中更新，或运行 ezx update%s\n' \
            "${C_GREEN}" "${latest}" "${current}" "${C_RESET}"
    fi
    interactive || { printf 'easyxray %s 已经安装。管理请运行 ezx\n' "${current}"; exit 0; }
    exec "${HOME_DIR}/easyxray"
fi

# 没有终端、也没有安装参数时无法询问，只有保留的配置可以直接恢复
if ! interactive && ((${#args[@]} == 0)) && ! kept_config; then
    die "当前没有终端，无法交互式安装。请加上安装参数，例如：bash install.sh --domain box.example.com"
fi

# ---------- 环境检查：先全部检查完再一起报告 ----------

FAILED=0
printf '\n检查环境\n'
pass "root 权限"

if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
    debian) if [[ "${VERSION_ID%%.*}" -ge 12 ]]; then pass "系统 Debian 12+ / Ubuntu 22.04+"; else fail "Debian 版本太旧（${VERSION_ID}），需要 12 或更新"; fi ;;
    ubuntu) if [[ "${VERSION_ID%%.*}" -ge 22 ]]; then pass "系统 Debian 12+ / Ubuntu 22.04+"; else fail "Ubuntu 版本太旧（${VERSION_ID}），需要 22.04 或更新"; fi ;;
    *) fail "不支持的系统：${PRETTY_NAME:-${ID:-未知}}，只支持 Debian 12+ 和 Ubuntu 22.04+" ;;
    esac
else
    fail "无法识别系统，只支持 Debian 12+ 和 Ubuntu 22.04+"
fi

case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) pass "CPU 架构 x86_64 / arm64" ;;
*) fail "不支持的 CPU 架构：$(uname -m)，只支持 x86_64 和 arm64" ;;
esac

if [[ -d /run/systemd/system ]]; then
    pass "systemd"
else
    fail "系统没有使用 systemd（常见于 OpenVZ/LXC 容器），无法安装服务"
fi

conflicts=()
[[ -d /etc/v2ray-agent ]] && conflicts+=("v2ray-agent（/etc/v2ray-agent）")
[[ -d /usr/local/x-ui ]] && conflicts+=("x-ui / 3x-ui（/usr/local/x-ui）")
for unit in xray v2ray sing-box hysteria-server x-ui; do
    systemctl is-active --quiet "${unit}" 2>/dev/null && conflicts+=("正在运行的 ${unit} 服务")
done
if ((${#conflicts[@]} == 0)); then
    pass "没有发现其他代理脚本或面板"
else
    fail "发现其他代理脚本或面板：${conflicts[*]}，请先卸载，避免端口和证书冲突"
fi

# 443 给 Reality-Vision；80 给 Nginx 申请证书（已有的 Nginx 占用 80 没关系）
owner() {
    local name
    name=$(ss -Hltnp "sport = :$1" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/users:(("//; s/"$//')
    printf '%s' "${name:-其他程序}"
}
if command -v ss >/dev/null 2>&1; then
    if [[ -z "$(ss -Hltn 'sport = :443' 2>/dev/null)" ]]; then
        pass "TCP 443 空闲（Reality-Vision）"
    else
        fail "TCP 443 已被 $(owner 443) 占用，Reality-Vision 需要使用 443"
    fi
    if [[ -z "$(ss -Hltn 'sport = :80' 2>/dev/null)" || "$(owner 80)" == "nginx" ]]; then
        pass "TCP 80 可用（申请证书）"
    else
        fail "TCP 80 已被 $(owner 80) 占用，申请证书需要用 Nginx 监听 80"
    fi
fi

# 纯 IPv6 VPS：GitHub 不支持 IPv6，无法下载 easyxray 和 Xray
if [[ -n "$(ip -4 route show default 2>/dev/null)" ]]; then
    pass "IPv4 网络"
else
    fail "没有 IPv4 网络：暂不支持纯 IPv6 VPS（GitHub 不支持 IPv6，无法下载 easyxray 和 Xray）"
fi

free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
if [[ "${free_mb:-0}" -ge 300 ]]; then
    pass "磁盘剩余空间 ≥ 300 MB"
else
    fail "磁盘剩余空间不足：${free_mb} MB，至少需要 300 MB"
fi

((FAILED == 0)) || die $'\n环境检查没有通过，请按上面的提示处理后重新运行'

# ---------- 下载工具和网络 ----------

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
[[ -d /etc/ssl/certs && -n "$(ls -A /etc/ssl/certs 2>/dev/null)" ]] || missing+=(ca-certificates)
if ((${#missing[@]} > 0)); then
    printf '  %s安装 %s...%s\n' "${C_DIM}" "${missing[*]}" "${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    # 通过 curl | bash 运行时脚本本身来自标准输入，apt-get 不能读走它
    { apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null; } </dev/null || die "安装 ${missing[*]} 失败，请检查 apt 软件源"
fi
pass "下载工具 curl"

if curl -fsSI -o /dev/null --max-time 15 https://github.com; then
    pass "可以访问 github.com"
else
    die "无法访问 github.com，请检查服务器的网络和 DNS"
fi

# ---------- 下载程序包并校验 ----------

if [[ -n "${version}" ]]; then
    base="https://github.com/${REPO}/releases/download/v${version}"
else
    base="https://github.com/${REPO}/releases/latest/download"
fi
base=${EZ_RELEASE_BASE:-${base}}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

printf '\n下载 easyxray%s\n' "${version:+ v${version}}"
curl -fsSL --retry 2 -o "${tmp}/easyxray.tar.gz" "${base}/easyxray.tar.gz" &&
    curl -fsSL --retry 2 -o "${tmp}/easyxray.tar.gz.sha256" "${base}/easyxray.tar.gz.sha256" ||
    die "下载失败：${base}/easyxray.tar.gz"
(cd "${tmp}" && sha256sum -c --status easyxray.tar.gz.sha256) || die "SHA256 校验失败，已停止安装"
pass "SHA256 校验通过"
mkdir "${tmp}/new"
tar -xzf "${tmp}/easyxray.tar.gz" -C "${tmp}/new" --no-same-owner && [[ -f "${tmp}/new/easyxray" ]] ||
    die "压缩包内容不正确，已停止安装"

# 程序目录已经存在时（例如保留配置卸载后），替换除 bin/（Xray）以外的文件
mkdir -p "${HOME_DIR}"
find "${HOME_DIR}" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
cp -a "${tmp}/new/." "${HOME_DIR}/"
chmod 755 "${HOME_DIR}/easyxray"
pass "已解压到 ${HOME_DIR}（$(sed -n 's/^EZ_VERSION=//p' "${HOME_DIR}/lib/common.sh")）"
printf '\n'
# exec 不会触发 EXIT trap，先删除临时目录
rm -rf "${tmp}"
trap - EXIT

# 有安装参数，或没有终端但有保留的配置：直接安装；否则进入安装菜单
if ((${#args[@]} > 0)) || ! interactive; then
    exec "${HOME_DIR}/easyxray" install "${args[@]}"
fi
exec "${HOME_DIR}/easyxray"
