# shellcheck shell=bash
# Nginx：80 端口（证书验证 + 跳转 HTTPS）、Reality 回落站点（127.0.0.1:31305，TLS）、Vision 回落站点（127.0.0.1:31306 HTTP/1.1，31308 HTTP/2）
# 订阅文件也由 Reality 回落站点提供：https://域名/s/<用户令牌>

# nginx 1.25.1 起用 "http2 on;"，更早的版本写在 listen 里
nginx_http2_new_syntax() {
    local v major minor patch
    v=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "${v}" ]] && return 0
    IFS=. read -r major minor patch <<<"${v}"
    ((major > 1 || (major == 1 && (minor > 25 || (minor == 25 && patch >= 1)))))
}

# 用自有域名证书提供伪装站点的 TLS server 块。用法：nginx_tls_server 监听地址 <<<"额外的 location 配置"
# 监听地址只写端口时同时监听 IPv4 和 IPv6
nginx_tls_server() {
    local addr=$1 extra suffix=' ssl' http2_line=''
    extra=$(cat)
    if nginx_http2_new_syntax; then http2_line='http2 on;'; else suffix=' ssl http2'; fi
    printf '\nserver {\n    listen %s%s;\n' "${addr}" "${suffix}"
    [[ "${addr}" == *:* ]] || printf '    listen [::]:%s%s;\n' "${addr}" "${suffix}"
    cat <<EOF
    ${http2_line}
    server_name $(state_get .domain);
    server_tokens off;
    ssl_certificate $(cert_file);
    ssl_certificate_key $(key_file);
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:easyxray:10m;
    ssl_session_timeout 1d;
    root ${EZ_WWW}/site;
    index index.html;
    error_page 404 /404.html;
EOF
    [[ -n "${extra}" ]] && printf '%s\n' "${extra}"
    cat <<'EOF'
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
}

render_nginx_conf() {
    local domain cert key p
    domain=$(state_get .domain)
    cert=$(cert_file)
    key=$(key_file)
    cat <<EOF
# 由 easyxray 生成，请勿手动修改
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    server_tokens off;
    location /.well-known/acme-challenge/ {
        root ${EZ_WWW}/acme;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    # 证书还没申请下来时只提供 80 端口
    [[ -s "${cert}" && -s "${key}" ]] || return 0

    # Reality 回落站点，同时提供订阅。正则里有 {32}，必须加引号，否则 Nginx 会把花括号当成配置块
    nginx_tls_server "127.0.0.1:${EZ_REALITY_TARGET_PORT}" <<EOF
    location ~ "^/s/(?<token>[0-9a-f]{32})\$" {
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-store" always;
        alias ${EZ_SUB}/\$token;
    }
EOF
    cat <<EOF

server {
    listen 127.0.0.1:${EZ_VISION_FALLBACK_PORT};
    server_name _;
    server_tokens off;
    root ${EZ_WWW}/site;
    index index.html;
    error_page 404 /404.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 127.0.0.1:${EZ_VISION_H2_FALLBACK_PORT}$(nginx_http2_new_syntax || printf ' http2');
    $(nginx_http2_new_syntax && printf 'http2 on;')
    server_name _;
    server_tokens off;
    root ${EZ_WWW}/site;
    index index.html;
    error_page 404 /404.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    # 由 Nginx 对外监听的协议（例如 XHTTP-TLS）
    while read -r p; do
        [[ -n "${p}" && "$(proto_listener "${p}")" == "nginx" ]] && proto_call "${p}" nginx
    done < <(enabled_protocols)
    return 0
}

# 首次安装时放一个简单的伪装站点；以后可以把自己的网站文件放进 ${EZ_WWW}/site
install_site() {
    mkdir -p "${EZ_WWW}/site" "${EZ_WWW}/acme"
    [[ -f "${EZ_WWW}/site/index.html" ]] || cp "${EZ_HOME}/templates/site/index.html" "${EZ_WWW}/site/index.html"
    [[ -f "${EZ_WWW}/site/404.html" ]] || cp "${EZ_HOME}/templates/site/404.html" "${EZ_WWW}/site/404.html"
    chmod -R a+rX "${EZ_WWW}"
}

nginx_test() {
    no_system && return 0
    nginx -t >/dev/null 2>&1
}

nginx_reload() {
    no_system && return 0
    systemctl enable nginx >/dev/null 2>&1
    if systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}
