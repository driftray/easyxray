# shellcheck shell=bash
# 用户管理：用户以邮箱标识，所有协议共用同一个 UUID；每个用户有独立的订阅令牌

valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

user_exists() {
    [[ -n "$(jq -r --arg e "$1" '.users[] | select(.email == $e) | .email' "${EZ_STATE}")" ]]
}

# 不填邮箱时生成 8 位随机前缀 @xray.fake，保证不重复
new_fake_email() {
    local email
    while :; do
        email="$(rand_alnum 8)@xray.fake"
        user_exists "${email}" || break
    done
    printf '%s' "${email}"
}

# 只改状态，不 apply
user_add_state() {
    local email=${1:-}
    [[ -z "${email}" ]] && email=$(new_fake_email)
    valid_email "${email}" || die "邮箱格式不正确：${email}"
    user_exists "${email}" && die "用户已存在：${email}"
    state_update '.users += [{email: $email, uuid: $uuid, subToken: $token, createdAt: $now}]' \
        --arg email "${email}" --arg uuid "$(new_uuid)" --arg token "$(rand_hex 32)" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s' "${email}"
}

user_del_state() {
    local email=$1
    user_exists "${email}" || die "没有这个用户：${email}"
    [[ "$(jq '.users | length' "${EZ_STATE}")" -gt 1 ]] || die "至少要保留一个用户"
    state_update 'del(.users[] | select(.email == $e))' --arg e "${email}"
}

user_list() {
    jq -r '.users[] | "\(.email)\t\(.uuid)"' "${EZ_STATE}" | column -t -s $'\t'
}
