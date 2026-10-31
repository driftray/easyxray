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
cp "${R}/etc/easyxray/tls/test.example.com.crt" "${R}/cert.crt" && cp "${R}/etc/easyxray/tls/test.example.com.key" "${R}/cert.key"

echo "安装"
x install --domain test.example.com --full >/dev/null 2>&1
check "完全安装后有 5 个入站" cfg '.inbounds | length == 5'
check "Xray 配置校验通过" xray_ok
check "状态文件记录了安装的 Xray 版本" jq -e --arg v "v$("${XRAY}" version | awk 'NR==1{print $2}')" '.xray.version == $v' "${R}/etc/easyxray/state.json"
check "Reality-Vision 在 443" cfg '.inbounds[] | select(.tag == "reality-vision") | .port == 443'
check "其他协议端口在 8000~8100" jq -e '[.protocols | to_entries[] | select(.key != "reality-vision") | .value.port] | all(. >= 8000 and . <= 8100)' "${R}/etc/easyxray/state.json"
N="${R}/etc/nginx/conf.d/easyxray.conf"
xport=$(jq -r '.protocols["xhttp-tls"].port' "${R}/etc/easyxray/state.json")
xpath=$(jq -r '.protocols["xhttp-tls"].path' "${R}/etc/easyxray/state.json")
check "XHTTP-TLS 的 Xray 只监听本机" cfg '.inbounds[] | select(.tag == "xhttp-tls") | .listen == "127.0.0.1" and .port == 31307 and .streamSettings.security == "none"'
check "XHTTP-TLS 端口由 Nginx 监听" grep -q "listen ${xport} ssl" "${N}"
check "XHTTP-TLS 路径用 grpc_pass 转给 Xray" grep -q "location ^~ ${xpath}/" "${N}"
check "XHTTP-TLS 传递真实 IP 且不可伪造" bash -c "grep -q 'grpc_set_header X-Forwarded-For \$remote_addr;' ${N} && jq -e '.inbounds[] | select(.tag == \"xhttp-tls\") | .streamSettings.sockopt.trustedXForwardedFor == [\"X-Forwarded-For\"]' ${C} >/dev/null"
check "TLS-Vision 支持 h2 并按 ALPN 回落" cfg '.inbounds[] | select(.tag == "vless-tls-vision") | .streamSettings.tlsSettings.alpn == ["h2", "http/1.1"] and .settings.fallbacks == [{alpn: "h2", dest: "127.0.0.1:31308"}, {dest: "127.0.0.1:31306"}]'
check "Nginx 有 HTTP/2 回落站点" grep -q "listen 127.0.0.1:31308" "${N}"
check "XHTTP-TLS 分享链接端口不变" bash -c "base64 -d <${R}/etc/easyxray/subscribe/* 2>/dev/null | grep -q 'type=xhttp&sni' && base64 -d <\$(ls ${R}/etc/easyxray/subscribe/* | head -1) | grep -q '@test.example.com:${xport}?encryption=none&security=tls&type=xhttp'"
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
check "QUIC 屏蔽排在分流规则之前" cfg '[.routing.rules[0:2][] | select(.network == "udp")] | length == 1'
x route quic allow >/dev/null 2>&1
x route del direct "1.2.3.0/24,geoip:cn" >/dev/null 2>&1
check "删掉 IP 规则后回到 AsIs" cfg '.routing.domainStrategy == "AsIs"'
check "QUIC 屏蔽已关闭" cfg '[.routing.rules[] | select(.network == "udp")] | length == 0'

echo "协议"
check "Reality-Vision 不能关闭" bash -c "! bash ${HERE}/easyxray protocol disable reality-vision"
check "不能换到低于安全版本的 Xray" bash -c "! bash ${HERE}/easyxray xray use v26.10.21 2>&1 | grep -q 已切换 && bash ${HERE}/easyxray xray use v26.10.21 2>&1 | grep -q 低于安全版本"
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
check "rollback 后状态文件和配置一致" jq -e '.protocols.hysteria2.enabled == true' "${R}/etc/easyxray/state.json"

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

echo "BT 屏蔽"
check "默认开启 BT 屏蔽，规则在最前面" cfg '.routing.rules[0] == {type: "field", protocol: ["bittorrent"], outboundTag: "block"}'
x route bt allow >/dev/null 2>&1
check "关闭后没有 BT 规则" cfg '[.routing.rules[] | select(.protocol)] | length == 0'
jq 'del(.routing.blockBT)' "${R}/etc/easyxray/state.json" >"${R}/s.tmp" && cat "${R}/s.tmp" >"${R}/etc/easyxray/state.json"
x apply >/dev/null 2>&1
check "旧版本状态文件没有这一项时默认开启" cfg '.routing.rules[0].protocol == ["bittorrent"]'

echo "重新生成密钥"
S="${R}/etc/easyxray/state.json"
jq -S '{users, ports: [.protocols[] | .port], vision: .protocols["reality-vision"], rx: .protocols["reality-xhttp"], hy: .protocols.hysteria2.obfsPassword, xp: .protocols["xhttp-tls"].path}' "${S}" >"${R}/rk.before"
x rekey >/dev/null 2>&1
rk() { jq -e --slurpfile b "${R}/rk.before" "$1" "${S}"; }
check "Reality-Vision 密钥和 shortId 已更换" rk '.protocols["reality-vision"] as $n | $b[0].vision as $o | $n.privateKey != $o.privateKey and $n.publicKey != $o.publicKey and $n.shortId != $o.shortId and ($n.privateKey | length) > 0'
check "Reality-XHTTP 密钥和路径已更换" rk '.protocols["reality-xhttp"] as $n | $b[0].rx as $o | $n.privateKey != $o.privateKey and $n.path != $o.path'
check "Hysteria2 混淆密码和 XHTTP-TLS 路径已更换" rk '(.protocols.hysteria2.obfsPassword != $b[0].hy) and (.protocols["xhttp-tls"].path != $b[0].xp)'
check "端口和用户不变" rk '([.protocols[] | .port] == $b[0].ports) and (.users == $b[0].users)'
check "重新生成后配置有效" xray_ok

echo "geo 数据"
G="${R}/geo-src" B="${R}/xbin"
mkdir -p "${G}/geoip" "${G}/geosite" "${B}"
cp "${XRAY}" "${B}/xray"
cp "$(dirname "${XRAY}")/geoip.dat" "$(dirname "${XRAY}")/geosite.dat" "${B}/"
cp "$(dirname "${XRAY}")/geoip.dat" "${G}/geoip/geoip-lite.dat"
cp "$(dirname "${XRAY}")/geosite.dat" "${G}/geosite/geosite.dat"
printf 'padding' >>"${G}/geosite/geosite.dat"
for f in geoip/geoip-lite.dat geosite/geosite.dat; do (cd "${G}/$(dirname "${f}")" && shasum -a 256 "$(basename "${f}")" >"$(basename "${f}").sha256sum"); done
geo() { EZ_XRAY_BIN="${B}/xray" EZ_GEO_BASE="file://${G}" bash "${HERE}/easyxray" geo update; }
cp "${G}/geosite/geosite.dat.sha256sum" "${R}/good.sum"
echo "0000  geosite.dat" >"${G}/geosite/geosite.dat.sha256sum"
check "校验不通过时拒绝更新" bash -c "! EZ_XRAY_BIN=${B}/xray EZ_GEO_BASE=file://${G} bash ${HERE}/easyxray geo update"
check "拒绝更新后数据不变" cmp -s "${B}/geosite.dat" "$(dirname "${XRAY}")/geosite.dat"
cp "${R}/good.sum" "${G}/geosite/geosite.dat.sha256sum"
geo >/dev/null 2>&1
check "校验通过后替换为新数据" cmp -s "${B}/geosite.dat" "${G}/geosite/geosite.dat"
check "数据相同时提示已经是最新" bash -c "EZ_XRAY_BIN=${B}/xray EZ_GEO_BASE=file://${G} bash ${HERE}/easyxray geo update 2>&1 | grep -q 已经是最新"

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

echo "备份与恢复"
mkdir -p "${R}/etc/easyxray/tls"
cp "${R}/cert.crt" "${R}/etc/easyxray/tls/test.example.com.crt" && cp "${R}/cert.key" "${R}/etc/easyxray/tls/test.example.com.key"
x install --domain test.example.com --full >/dev/null 2>&1
x user add bob@example.com >/dev/null 2>&1
jq -S '{users, protocols, routing}' "${S}" >"${R}/bk.before"
x backup "${R}/bk.tar.gz" >/dev/null 2>&1
check "备份文件权限是 600" bash -c "[[ \$(stat -c %a ${R}/bk.tar.gz 2>/dev/null || stat -f %Lp ${R}/bk.tar.gz) == 600 ]]"
check "已安装时拒绝恢复" bash -c "! bash ${HERE}/easyxray install --restore ${R}/bk.tar.gz"
echo y | x uninstall --purge >/dev/null 2>&1
mkdir -p "${R}/etc/easyxray/tls"
cp "${R}/cert.crt" "${R}/etc/easyxray/tls/test.example.com.crt" && cp "${R}/cert.key" "${R}/etc/easyxray/tls/test.example.com.key"
x install --restore "${R}/bk.tar.gz" >/dev/null 2>&1
jq -S '{users, protocols, routing}' "${S}" >"${R}/bk.after"
check "恢复后用户、密钥、端口和规则与备份时一致" cmp -s "${R}/bk.before" "${R}/bk.after"
check "恢复后标记为已安装、配置有效" bash -c "jq -e '.system.installed == true' ${S} >/dev/null && XRAY_LOCATION_ASSET=$(dirname "${XRAY}") ${XRAY} run -test -confdir ${R}/etc/easyxray/xray >/dev/null"

printf '\n通过 %d，失败 %d\n' "${pass}" "${fail}"
((fail == 0))
