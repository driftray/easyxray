# shellcheck shell=bash
# 分流规则：状态里按「出口 + 域名列表 + IP 列表」存储，每个出口一条，生成配置时再展开

# geosite 里有没有这个分类：用 xray run -test 实际加载一次，和 Xray 运行时的判断完全一致
# 配置从标准输入传入（Xray 按文件后缀判断格式，临时文件没有 .json 后缀会读取失败）
geosite_exists() {
    printf '{"outbounds":[{"protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["geosite:%s"],"outboundTag":"direct"}]}}' "$1" |
        XRAY_LOCATION_ASSET="$(dirname "${EZ_XRAY_BIN}")" "${EZ_XRAY_BIN}" run -test -c stdin: >/dev/null 2>&1
}

# 把一项输入分类为 domain 或 ip，并规范成 Xray 的写法；无法识别时返回 1
# 不带前缀的单词（例如 anthropic）默认当作 geosite 分类，带点的当作域名
classify_rule_item() {
    local item=$1
    item=${item// /}
    [[ -z "${item}" ]] && return 1
    case "${item}" in
    geoip:*)
        printf 'ip\t%s\n' "${item}"
        ;;
    geosite:* | domain:* | full:* | regexp:* | keyword:*)
        printf 'domain\t%s\n' "${item}"
        ;;
    *)
        if [[ "${item}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "${item}" =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]]; then
            printf 'ip\t%s\n' "${item}"
        elif [[ "${item}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
            # 普通域名按「该域名及其所有子域名」匹配
            printf 'domain\tdomain:%s\n' "${item,,}"
        elif [[ "${item}" =~ ^[A-Za-z0-9!@_-]+$ ]]; then
            # 单词：去 geosite 列表里查，例如 anthropic、openai、netflix、category-ads-all
            geosite_exists "${item,,}" || return 2
            printf 'domain\tgeosite:%s\n' "${item,,}"
        else
            return 1
        fi
        ;;
    esac
}

outbound_exists() {
    [[ "$1" == "direct" || "$1" == "block" ]] && return 0
    [[ -n "$(jq -r --arg o "$1" '.outbounds[$o] // empty' "${EZ_STATE}")" ]]
}

# route_add 出口 "a.com,geosite:cn,1.2.3.0/24"
route_add_state() {
    local outbound=$1 items=$2 item kind value rc domains=() ips=() bad=() missing=()
    outbound_exists "${outbound}" || die "没有这个出口：${outbound}（WARP 需要先运行 warp setup）"
    IFS=',' read -ra list <<<"${items}"
    for item in "${list[@]}"; do
        [[ -z "${item// /}" ]] && continue
        value=$(classify_rule_item "${item}")
        rc=$?
        if ((rc == 0)); then
            kind=${value%%$'\t'*}
            value=${value#*$'\t'}
            [[ "${kind}" == "ip" ]] && ips+=("${value}") || domains+=("${value}")
        elif ((rc == 2)); then
            missing+=("${item// /}")
        else
            bad+=("${item}")
        fi
    done
    ((${#missing[@]} == 0)) || die "geosite 里没有这些分类：${missing[*]}。如果是网站域名，请写完整，例如 example.com"
    ((${#bad[@]} == 0)) || die "无法识别：${bad[*]}"
    ((${#domains[@]} + ${#ips[@]} > 0)) || die "没有要添加的规则"
    state_update '
        (if any(.routing.rules[]?; .outbound == $o) then . else .routing.rules += [{outbound: $o, domains: [], ips: []}] end)
        | .routing.rules |= map(if .outbound == $o then
            .domains = (((.domains // []) + $d) | unique) | .ips = (((.ips // []) + $i) | unique) else . end)' \
        --arg o "${outbound}" \
        --argjson d "$(printf '%s\n' "${domains[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
        --argjson i "$(printf '%s\n' "${ips[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
}

# route_del 出口 [项目列表]；不给项目时删除该出口的全部规则
route_del_state() {
    local outbound=$1 items=${2:-} item kind value values=()
    if [[ -z "${items}" ]]; then
        state_update '.routing.rules |= map(select(.outbound != $o))' --arg o "${outbound}"
        return
    fi
    IFS=',' read -ra list <<<"${items}"
    for item in "${list[@]}"; do
        read -r kind value < <(classify_rule_item "${item}") && values+=("${value}")
    done
    state_update '.routing.rules |= map(if .outbound == $o then .domains -= $v | .ips -= $v else . end)
        | .routing.rules |= map(select(((.domains // []) + (.ips // [])) | length > 0))' \
        --arg o "${outbound}" --argjson v "$(printf '%s\n' "${values[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
}

route_list() {
    jq -r '.routing.rules[]? | "\(.outbound):\n  " + (((.domains // []) + (.ips // [])) | join("\n  "))' "${EZ_STATE}"
    printf 'QUIC 屏蔽：%s\n' "$([[ "$(state_get '.routing.blockQUIC')" == "true" ]] && echo 开启 || echo 关闭)"
    printf 'BT 屏蔽：%s\n' "$(bt_blocked && echo 开启 || echo 关闭)"
}

# BT 屏蔽默认开启：状态文件里没有这一项时也算开启
bt_blocked() { [[ "$(jq -r '.routing.blockBT != false' "${EZ_STATE}")" == "true" ]]; }
