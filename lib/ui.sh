# shellcheck shell=bash
# 菜单界面：只画左边框，避免中文宽度不一致时右边框对不齐；两列菜单按显示宽度补齐

if [[ -t 1 ]]; then
    C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_CYAN=$'\e[36m'
else
    C_DIM='' C_BOLD='' C_CYAN=''
fi
UI_WIDTH=56

# 显示宽度：ASCII 占 1 列，中文（UTF-8 中 3 个字节）占 2 列。不依赖语言环境，非 UTF-8 环境下也能对齐
display_width() {
    local s=$1 ascii wide
    ascii=$(printf '%s' "${s}" | LC_ALL=C tr -d '\200-\377' | wc -c | tr -d ' ')
    wide=$(printf '%s' "${s}" | LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d ' ')
    printf '%s' $((ascii + wide * 2 / 3))
}

# 把文字补齐到指定显示宽度
pad() {
    local s=$1 width=$2 w
    w=$(display_width "${s}")
    printf '%s%*s' "${s}" $((width > w ? width - w : 0)) ''
}

ui_rule() {
    local corner=${1:-├} line
    printf -v line '%*s' "${UI_WIDTH}" ''
    printf '%s%s%s\n' "${C_DIM}" "${corner}${line// /─}" "${C_RESET}"
}
ui_top() { ui_rule ╭; }
ui_bottom() { ui_rule ╰; }
ui_row() { printf '%s│%s %s\n' "${C_DIM}" "${C_RESET}" "$*"; }
ui_title() { ui_row "${C_BOLD}$*${C_RESET}"; }
ui_blank() { printf '%s│%s\n' "${C_DIM}" "${C_RESET}"; }

# 两列菜单：ui_menu "1" "查看订阅" "2" "用户管理"
ui_menu() {
    local left right=''
    left="${C_CYAN}$(pad "$1" 2)${C_RESET} $(pad "$2" 20)"
    [[ -n "${3:-}" ]] && right="${C_CYAN}$(pad "$3" 2)${C_RESET} $4"
    ui_row "${left}${right}"
}

ui_status_dot() {
    if [[ "$1" == "on" ]]; then printf '%s●%s' "${C_GREEN}" "${C_RESET}"; else printf '%s○%s' "${C_DIM}" "${C_RESET}"; fi
}

ui_ask() {
    local var
    read -r -p "$(printf '%s›%s %s' "${C_CYAN}" "${C_RESET}" "$1")" var
    printf '%s' "${var}"
}

ui_pause() {
    read -r -p "$(printf '\n%s按回车返回菜单%s' "${C_DIM}" "${C_RESET}")" _
}

# 标志和简介
ui_banner() {
    ui_top
    ui_blank
    ui_row "  ${C_CYAN}┌─┐┌─┐┌─┐┬ ┬─┐ ┬┬─┐┌─┐┬ ┬${C_RESET}"
    ui_row "  ${C_CYAN}├┤ ├─┤└─┐└┬┘┌┴┬┘├┬┘├─┤└┬┘${C_RESET}   ${C_DIM}v${EZ_VERSION}${C_RESET}"
    ui_row "  ${C_CYAN}└─┘┴ ┴└─┘ ┴ ┴ └─┴└─┴ ┴ ┴${C_RESET}"
    ui_row "  ${C_BOLD}简单、安全的 Xray 服务器管理工具${C_RESET}"
    ui_row "  ${C_DIM}改动前自动校验 · 失败自动回滚 · 一个文件管理全部配置${C_RESET}"
    ui_blank
}

# 状态面板：域名、服务状态、用户数、WARP、各协议端口
ui_dashboard() {
    local svc users warp p state line
    if no_system || systemctl is-active easyxray >/dev/null 2>&1; then
        svc="$(ui_status_dot on) Xray $(xray_installed_version) ${C_GREEN}运行中${C_RESET}"
    else
        svc="${C_RED}● Xray $(xray_installed_version) 未运行${C_RESET}"
    fi
    users=$(jq '.users | length' "${EZ_STATE}")
    if [[ -n "$(state_get '.outbounds["warp-ipv4"].privateKey')" ]]; then
        warp="$(ui_status_dot on) WARP 已开启"
    else
        warp="$(ui_status_dot off) ${C_DIM}WARP 未开启${C_RESET}"
    fi
    ui_banner
    ui_rule
    ui_row "${C_DIM}域名${C_RESET}   $(state_get .domain)"
    ui_row "${C_DIM}状态${C_RESET}   ${svc}    用户 ${users}    ${warp}"
    ui_rule
    for p in "${EZ_PROTOCOLS[@]}"; do
        if protocol_enabled "${p}"; then
            state="$(proto_call "${p}" transport | tr '[:lower:]' '[:upper:]') $(proto_get "${p}" .port)"
            line="$(ui_status_dot on) $(pad "$(proto_call "${p}" title)" 20)${state}"
        else
            line="$(ui_status_dot off) ${C_DIM}$(pad "$(proto_call "${p}" title)" 20)未开启${C_RESET}"
        fi
        ui_row "${line}"
    done
}
