#!/usr/bin/env bash
# 冒烟测试：在临时目录里以测试模式（EZ_NO_SYSTEM=1）跑一遍安装和常用命令，检查生成的配置
# 用法：XRAY=/path/to/xray bash tests/smoke.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
XRAY=${XRAY:?请用 XRAY=/path/to/xray 指定 xray 程序}
R=$(mktemp -d)
trap 'rm -rf "${R}"' EXIT
export EZ_ROOT="${R}" EZ_HOME="${HERE}" EZ_NO_SYSTEM=1 EZ_XRAY_BIN="${XRAY}"
C="${R}/etc/easyxray/xray/config.json"
pass=0 fail=0

x() { bash "${HERE}/easyxray" "$@"; }
check() {
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
        printf '  ok    %s\n' "${name}"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s\n' "${name}"
    fi
}
cfg() { jq -e "$1" "${C}"; }
xray_ok() { XRAY_LOCATION_ASSET=$(dirname "${XRAY}") "${XRAY}" run -test -confdir "${R}/etc/easyxray/xray"; }

mkdir -p "${R}/etc/easyxray/tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=test.example.com" \
    -keyout "${R}/etc/easyxray/tls/test.example.com.key" -out "${R}/etc/easyxray/tls/test.example.com.crt" 2>/dev/null

echo "安装"
x install --domain test.example.com --full >/dev/null 2>&1
check "完全安装后有 5 个入站" cfg '.inbounds | length == 5'
check "Xray 配置校验通过" xray_ok
check "Reality-Vision 在 443" cfg '.inbounds[] | select(.tag == "reality-vision") | .port == 443'
check "其他协议端口在 8000~8100" cfg '[.inbounds[] | select(.tag != "reality-vision") | .port] | all(. >= 8000 and . <= 8100)'
check "端口互不重复" cfg '[.inbounds[].port] | length == (unique | length)'
check "所有入站开启嗅探 routeOnly" cfg '[.inbounds[].sniffing.routeOnly] | all'
check "Reality shortId 不是旧脚本的固定值" cfg '[.inbounds[] | .streamSettings.realitySettings.shortIds? // empty | .[]] | all(. != "6ba85179e30d4fc2")'
check "默认不屏蔽 QUIC" cfg '[.routing.rules[] | select(.network == "udp")] | length == 0'
sub_file=$(ls "${R}"/etc/easyxray/subscribe/* | head -1)
check "订阅链接不含 fp" bash -c "! base64 -d < ${sub_file} | grep -q 'fp='"
check "订阅有 5 条链接" bash -c "[[ \$(base64 -d < ${sub_file} | wc -l) -eq 5 ]]"
check "第一个用户是 @xray.fake" bash -c "grep -q '@xray.fake' ${R}/etc/easyxray/state.json"

echo "用户"
x user add alice@example.com >/dev/null 2>&1
x user add >/dev/null 2>&1
check "加两个用户后每个入站 3 个用户" cfg '[.inbounds[] | (.settings.clients // .settings.users) | length] | all(. == 3)'
check "重复邮箱被拒绝" bash -c "! bash ${HERE}/easyxray user add alice@example.com"
check "错误邮箱被拒绝" bash -c "! bash ${HERE}/easyxray user add not-an-email"
check "每个用户一个订阅文件" bash -c "[[ \$(ls ${R}/etc/easyxray/subscribe | wc -l) -eq 3 ]]"
x user del alice@example.com >/dev/null 2>&1
check "删除后配置里没有 alice" bash -c "! grep -q alice ${C}"
check "删除后订阅文件剩 2 个" bash -c "[[ \$(ls ${R}/etc/easyxray/subscribe | wc -l) -eq 2 ]]"

echo "分流"
x route add direct "geosite:cn,Example.COM,1.2.3.0/24,geoip:cn" >/dev/null 2>&1
check "域名规则规范为 domain:" cfg '.routing.rules[] | select(.domain) | .domain | index("domain:example.com")'
check "有 IP 规则时 IPIfNonMatch" cfg '.routing.domainStrategy == "IPIfNonMatch"'
check "未配置 WARP 时拒绝 warp-ipv4 规则" bash -c "! bash ${HERE}/easyxray route add warp-ipv4 geosite:anthropic"
check "无法识别的规则被拒绝" bash -c "! bash ${HERE}/easyxray route add direct 'not a domain'"
x route add direct "anthropic,OpenAI" >/dev/null 2>&1
check "不带前缀的名称识别为 geosite" cfg '.routing.rules[] | select(.domain) | .domain | (index("geosite:anthropic") and index("geosite:openai"))'
check "geosite 里没有的名称被拒绝" bash -c "! bash ${HERE}/easyxray route add direct notexist123"
check "被拒绝时规则不变" bash -c "! grep -q notexist123 ${R}/etc/easyxray/state.json"
x route del direct "anthropic,openai" >/dev/null 2>&1
check "用名称删除 geosite 规则" bash -c "! grep -q 'geosite:anthropic' ${R}/etc/easyxray/state.json"
x route quic block >/dev/null 2>&1
check "QUIC 屏蔽排在第一条" cfg '.routing.rules[0] == {type: "field", network: "udp", port: "443", outboundTag: "block"}'
x route quic allow >/dev/null 2>&1
x route del direct "1.2.3.0/24,geoip:cn" >/dev/null 2>&1
check "删掉 IP 规则后回到 AsIs" cfg '.routing.domainStrategy == "AsIs"'
check "QUIC 屏蔽已关闭" cfg '[.routing.rules[] | select(.network == "udp")] | length == 0'

echo "协议"
check "Reality-Vision 不能关闭" bash -c "! bash ${HERE}/easyxray protocol disable reality-vision"
port_before=$(jq -r '.inbounds[] | select(.tag == "vless-tls-vision") | .port' "${C}")
x protocol disable vless-tls-vision >/dev/null 2>&1
check "关闭后少一个入站" cfg '.inbounds | length == 4'
x protocol enable vless-tls-vision >/dev/null 2>&1
check "重新开启后沿用原端口" cfg ".inbounds[] | select(.tag == \"vless-tls-vision\") | .port == ${port_before}"

echo "apply 与回滚"
before=$(jq -S . "${C}")
x apply >/dev/null 2>&1
check "连续 apply 配置不变" bash -c "[[ \"\$(jq -S . ${C})\" == '${before//\'/}' ]]"
cp "${R}/etc/easyxray/state.json" "${R}/state.ok"
jq '.protocols["hysteria2"].port = 443' "${R}/state.ok" >"${R}/etc/easyxray/state.json"
x apply >/dev/null 2>&1
check "端口冲突时 apply 失败且旧配置保留" cfg '.inbounds | length == 5'
cp "${R}/state.ok" "${R}/etc/easyxray/state.json"
x protocol disable hysteria2 >/dev/null 2>&1
x rollback >/dev/null 2>&1
check "rollback 恢复到关闭 Hysteria2 之前" cfg '[.inbounds[].tag] | index("hysteria2")'

echo "更新"
# 在程序目录的副本上测试，用本地目录代替 Release 下载地址；发布包里的版本号改成 9.9.9 以便确认已替换
P="${R}/prog" REL="${R}/rel"
mkdir -p "${P}" "${REL}/src"
(cd "${HERE}" && tar --exclude .git --exclude tests --exclude tools -cf - .) | tar -xf - -C "${REL}/src"
(cd "${HERE}" && tar --exclude .git -cf - .) | tar -xf - -C "${P}"
mkdir -p "${P}/bin" "${P}/.git" && touch "${P}/bin/marker"
perl -pi -e 's/^EZ_VERSION=.*/EZ_VERSION=9.9.9/' "${REL}/src/lib/common.sh"
(cd "${REL}/src" && tar -czf ../easyxray.tar.gz .) && (cd "${REL}" && shasum -a 256 easyxray.tar.gz >easyxray.tar.gz.sha256)
up() { EZ_HOME="${P}" EZ_RELEASE_BASE="file://${REL}" bash "${P}/easyxray" update "$@"; }
cp "${REL}/easyxray.tar.gz.sha256" "${REL}/good.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000  easyxray.tar.gz" >"${REL}/easyxray.tar.gz.sha256"
check "SHA256 不符时拒绝更新" bash -c "! EZ_HOME=${P} EZ_RELEASE_BASE=file://${REL} bash ${P}/easyxray update 9.9.9"
check "拒绝更新后程序没有变化" cmp -s "${HERE}/lib/common.sh" "${P}/lib/common.sh"
cp "${REL}/good.sha256" "${REL}/easyxray.tar.gz.sha256"
up 9.9.9 >/dev/null 2>&1
check "更新后是新版本" grep -q '^EZ_VERSION=9.9.9' "${P}/lib/common.sh"
check "更新保留 bin/ 里的 Xray" test -f "${P}/bin/marker"
check "更新删除 git clone 留下的 .git" test ! -e "${P}/.git"
check "更新后配置仍然有效" xray_ok

echo "卸载"
S="${R}/etc/easyxray/state.json"
jq -S '{users, protocols}' "${S}" >"${R}/keys.before"
echo n | x uninstall --keep-config >/dev/null 2>&1
check "回答 n 时不卸载" jq -e '.system.installed == true' "${S}"
echo y | x uninstall --keep-config >/dev/null 2>&1
check "保留配置卸载后状态文件还在" jq -e '.system.installed == false' "${S}"
x install >/dev/null 2>&1
check "重新安装不用填域名，标记为已安装" jq -e '.system.installed == true' "${S}"
jq -S '{users, protocols}' "${S}" >"${R}/keys.after"
check "重新安装沿用用户、端口和密钥" cmp -s "${R}/keys.before" "${R}/keys.after"
check "重新安装后配置有效" xray_ok
echo y | x uninstall --purge >/dev/null 2>&1
check "完全卸载删除 /etc/easyxray" test ! -e "${R}/etc/easyxray"
check "测试模式下完全卸载不删除源码目录" test -f "${HERE}/easyxray"

printf '\n通过 %d，失败 %d\n' "${pass}" "${fail}"
((fail == 0))
