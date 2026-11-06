# shellcheck shell=bash
# 无域名模式的 Reality 伪装域名：内置候选名单，以及从本机探测哪些域名可用、延迟多少
#
# 可用的条件：支持 TLS 1.3、HTTP/2 和 X25519，不在 Cloudflare 后面（Cloudflare 的域名会让别人能借你的服务器访问 Cloudflare 上的站点）
# 候选是各地区企业的官网，不在 gfwlist 里，由探测按延迟挑离服务器最近的；不选 Apple、Microsoft 这类特别大的网站，也不选常见教程里被大量使用的域名

EZ_TARGET_CANDIDATES=(
    # 亚洲
    www.lg.com www.asus.com www.foxconn.com www.singtel.com www.capitaland.com
    www.cathaypacific.com www.mtr.com.hk www.murata.com
    www.infosys.com www.wipro.com www.larsentoubro.com
    # 大洋洲
    www.bhp.com www.telstra.com.au
    # 欧洲
    www.siemens.com www.basf.com www.zeiss.com www.schneider-electric.com www.asml.com
    www.logitech.com www.maersk.com www.inditex.com www.eni.com www.pirelli.com
    # 美洲
    www.3m.com www.deere.com www.honeywell.com www.corning.com www.whirlpool.com www.rbc.com
    # 非洲
    www.sasol.com
)

EZ_TARGET_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'

valid_target() { [[ "$1" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && "$1" =~ \.[A-Za-z]{2,}$ ]]; }

# 探测一个域名，输出一行：域名<TAB>延迟毫秒<TAB>结果（"ok"、"ok:提示" 或失败原因）
target_probe_one() {
    local d=$1 out t code location server host i tmp
    tmp=$(mktemp)
    rm -f "${tmp}"
    if [[ -z "$(getent ahostsv4 "${d}" 2>/dev/null)" ]]; then
        printf '%s\t-\t无法解析域名\n' "${d}"
        return 0
    fi
    out=$(timeout 8 openssl s_client -connect "${d}:443" -servername "${d}" -tls1_3 -groups X25519 -alpn h2 </dev/null 2>/dev/null | LC_ALL=C tr -d "\000")
    if ! grep -q 'TLSv1.3' <<<"${out}"; then
        printf '%s\t-\t不支持 TLS 1.3 + X25519\n' "${d}"
        return 0
    fi
    if ! grep -q 'ALPN protocol: h2' <<<"${out}"; then
        printf '%s\t-\t不支持 HTTP/2\n' "${d}"
        return 0
    fi
    # 连接时间（不含域名解析）在后台测两次，和下面的请求同时进行。telnet:// 只建立 TCP 连接，1 秒后自己退出
    for i in 1 2; do
        curl -s -m 1 -w '%{time_namelookup} %{time_connect}\n' "telnet://${d}:443" </dev/null >"${tmp}.${i}" 2>/dev/null &
    done
    # 只取响应头（HEAD），不下载网页：状态码、跳转地址、Server 头和第三次连接时间
    out=$(curl -s -I -m 5 -A "${EZ_TARGET_UA}" -w 'EZ %{http_code} %{time_namelookup} %{time_connect}\n' "https://${d}/" 2>/dev/null | tr -d '\r')
    code=$(awk '/^EZ /{print $2}' <<<"${out}")
    location=$(awk 'tolower($1) == "location:" {print $2; exit}' <<<"${out}")
    server=$(awk 'tolower($1) == "server:" {print tolower($2); exit}' <<<"${out}")
    if [[ "${server}" == cloudflare* ]] || curl -s -m 3 "https://${d}/cdn-cgi/trace" 2>/dev/null | grep -aq "^visit_scheme="; then
        wait
        rm -f "${tmp}".*
        printf '%s\t-\t在 Cloudflare 后面，不能使用\n' "${d}"
        return 0
    fi
    wait
    # 连接失败时 curl 输出的连接时间是 0，不计入；取三次的中位数
    t=$( { awk '/^EZ /{print $3, $4}' <<<"${out}"; cat "${tmp}".*; } |
        awk '$2 > 0 {printf "%d\n", ($2 - $1) * 1000 + 0.5}' | sort -n | awk '{a[++n]=$1} END{print (n ? a[int((n + 1) / 2)] : "-")}')
    rm -f "${tmp}".*
    if [[ -z "${code}" || "${code}" == 000 ]]; then
        printf '%s\t%s\tok:网页没有响应\n' "${d}" "${t}"
    elif [[ "${code}" == 3* && -n "${location}" ]]; then
        host=${location#*://}
        host=${host%%/*}
        if [[ "${location}" == /* || "${host}" == "${d}" ]]; then
            printf '%s\t%s\tok\n' "${d}" "${t}"
        else
            printf '%s\t%s\tok:跳转到 %s\n' "${d}" "${t}" "${host}"
        fi
    else
        printf '%s\t%s\tok\n' "${d}" "${t}"
    fi
}

# 探测多个域名（同时最多 8 个，配置低的服务器同时连太多会把延迟测高），按「可用、延迟从低到高」排序输出
target_probe() {
    local tmp d i=0
    tmp=$(mktemp -d)
    for d in "$@"; do
        # 重定向在后台子进程里展开，序号要先在这里加好
        i=$((i + 1))
        while (($(jobs -rp | wc -l) >= 8)); do wait -n; done
        target_probe_one "${d}" >"${tmp}/${i}" &
    done
    wait
    cat "${tmp}"/* | awk -F'\t' '{ok = ($3 ~ /^ok/); plain = ($3 == "ok"); printf "%d\t%d\t%s\t%s\n", !ok, !plain, ($2 == "-" ? 999999 : $2), $0}' |
        sort -t$'\t' -k1,1n -k2,2n -k3,3n | cut -f4-
    rm -rf "${tmp}"
}

# 打印探测结果：$1=推荐的域名（标出来），$2=numbered 时在前面加编号（菜单里选择用）
target_probe_print() {
    local best=$1 d ms result note n=0 num=''
    while IFS=$'\t' read -r d ms result; do
        n=$((n + 1))
        [[ "${2:-}" == numbered ]] && num="${C_CYAN}$(pad "${n}" 3)${C_RESET}"
        if [[ "${result}" == ok* ]]; then
            [[ "${ms}" == 0 ]] && ms='<1'
            note=${result#ok}
            printf '  %s%s %s%s\n' "${num}" "$(pad "${d}" 26)" "$(pad "${ms} ms" 9)" \
                "${C_GREEN}可用${C_RESET}${note:+（${note#:}）}$([[ "${d}" == "${best}" ]] && printf '  %s← 推荐%s' "${C_CYAN}" "${C_RESET}")"
        else
            printf '  %s%s %s%s\n' "${num}" "$(pad "${d}" 26)" "$(pad "-" 9)" "${C_DIM}${result}${C_RESET}"
        fi
    done
}

# 推荐的域名：在延迟比最低值高不到 5 ms 的可用域名里随机选一个（首页不跳转的优先），
# 同一地区的服务器不会都选到名单里的第一个
target_best() {
    local list
    list=$(awk -F'\t' '
        $3 ~ /^ok/ { plain = ($3 == "ok"); if (!(plain in min) || $2 < min[plain]) min[plain] = $2; d[NR] = $1; ms[NR] = $2; p[NR] = plain }
        END {
            want = (1 in min) ? 1 : 0
            for (i in d) if (p[i] == want && ms[i] <= min[want] + 5) print d[i]
        }')
    [[ -n "${list}" ]] || return 0
    sed -n "$((RANDOM % $(wc -l <<<"${list}") + 1))p" <<<"${list}"
}

# 检查用户指定的伪装域名：不可用时停止，有提示（例如跳转到其他域名）时只提醒
target_check() {
    local d=$1 result
    valid_target "${d}" || die "伪装域名格式不正确：${d}（例如 www.example.com）"
    no_system && return 0
    info "检查伪装域名 ${d}..."
    result=$(target_probe_one "${d}" | cut -f3)
    case "${result}" in
    ok) ;;
    ok:*) warn "伪装域名 ${d}：${result#ok:}，可以使用，但最好换一个首页不跳转的网站" ;;
    *) die "伪装域名 ${d} 不能使用：${result}" ;;
    esac
}
