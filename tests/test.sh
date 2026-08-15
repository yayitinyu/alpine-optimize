#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"

export ALPINE_OPTIMIZE_SKIP_OS_CHECK=1
export ALPINE_OPTIMIZE_SKIP_ROOT_CHECK=1
export REALM_SKIP_ROOT_CHECK=1
export NO_COLOR=1

# shellcheck disable=SC1091
. "${ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/modules/optimize.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/modules/realm.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/modules/sing-box.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/modules/socks.sh"

pass_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$expected" == "$actual" ]] || fail "$name (expected=$expected actual=$actual)"
    pass "$name"
}

assert_true() {
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_false() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name"
    else
        pass "$name"
    fi
}

assert_file_contains() {
    local file="$1" text="$2" name="$3"
    grep -Fq "$text" "$file" || fail "$name"
    pass "$name"
}

# --- common helpers ---
assert_true "valid ipv4" is_valid_ipv4 1.2.3.4
assert_false "invalid ipv4" is_valid_ipv4 1.2.3.256
assert_true "valid host" is_valid_host example.com
assert_false "invalid host" is_valid_host "bad host"
assert_true "valid port 443" is_valid_port 443
assert_false "port 0 invalid for helper" is_valid_port 0

hex="$(random_hex 8)"
[[ "$hex" =~ ^[0-9a-f]{8}$ ]] || fail "random_hex length/charset"
pass "random_hex produces 8 hex chars"

# --- optimize buffers ---
MEM_MB=1024
assert_eq "16" "$(calculate_buffer_mb 1000 asia)" "asia 1g buffer on 1G RAM"
MEM_MB=256
asia256="$(calculate_buffer_mb 1000 asia)"
((asia256 <= 32)) || fail "low-memory buffer should be capped"
pass "low-memory buffer is capped (${asia256} MB)"

MEM_MB=4096
overseas="$(calculate_buffer_mb 1000 overseas)"
asia="$(calculate_buffer_mb 1000 asia)"
((overseas > asia)) || fail "overseas buffer should exceed asia at same bandwidth"
pass "overseas buffer exceeds asia (${overseas} > ${asia})"

# --- community repo helper ---
repo_tmp="$(mktemp)"
register_temp "$repo_tmp"
printf '%s\n%s\n' \
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" \
    "#https://dl-cdn.alpinelinux.org/alpine/v3.21/community" \
    >"$repo_tmp"
enable_community_repo "$repo_tmp"
assert_file_contains "$repo_tmp" "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" \
    "commented community repo is enabled"

repo_tmp2="$(mktemp)"
register_temp "$repo_tmp2"
printf '%s\n' "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" >"$repo_tmp2"
enable_community_repo "$repo_tmp2"
assert_file_contains "$repo_tmp2" "/community" "missing community repo is appended"

# --- realm listen / remote ---
assert_eq "0.0.0.0:23456" "$(normalize_listen 23456)" "port-only listen is normalized"
assert_eq "[::]:443" "$(normalize_listen '[::]:443')" "IPv6 listen is accepted"
assert_false "out-of-range port is rejected" normalize_listen 70000
assert_false "unsafe remote is rejected" validate_remote_endpoint "host name:443"
assert_true "ascii remote is accepted" validate_remote_endpoint example.com:443

state="$(mktemp)"
config="$(mktemp)"
register_temp "$state"
register_temp "$config"
printf '# id\tlisten\tremote\n' >"$state"
id1="$(append_route_to_state "$state" 23456 example.com:443)"
id2="$(append_route_to_state "$state" '[::]:5353' '[2001:db8::1]:53')"
assert_eq "1" "$id1" "first route ID"
assert_eq "2" "$id2" "second route ID"
assert_false "duplicate route is rejected" append_route_to_state "$state" 23456 example.com:443

render_config "$state" tcp "$config"
assert_file_contains "$config" "no_tcp = false" "TCP config enables TCP"
assert_file_contains "$config" "use_udp = false" "TCP config disables UDP"
assert_file_contains "$config" 'listen = "0.0.0.0:23456"' "config contains normalized listen"
assert_file_contains "$config" 'remote = "[2001:db8::1]:53"' "config contains IPv6 remote"
assert_file_contains "$config" "$MANAGED_MARKER" "rendered config is marked managed"

release_json="$(mktemp)"
register_temp "$release_json"
printf '%s' '{"tag_name":"v9.8.7","assets":[{"name":"realm-other.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"realm-test.tar.gz","uploader":{"name":"bot"},"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' >"$release_json"
assert_eq "v9.8.7" "$(parse_release_tag "$release_json")" "minified release tag is parsed"
assert_eq "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "$(parse_asset_digest "$release_json" "realm-test.tar.gz")" \
    "digest is selected for the requested asset"

# musl target on Alpine-like detection
if [[ "$(uname -s)" != "Linux" ]]; then
    REALM_TARGET="x86_64-unknown-linux-musl"
    assert_eq "x86_64-unknown-linux-musl" "$(detect_target)" "REALM_TARGET override works"
else
    target="$(detect_target)"
    [[ "$target" == *linux-* ]] || fail "detect_target returned unexpected value: $target"
    pass "detect_target returns a linux triple ($target)"
fi

# --- sing-box share links ---
vless="$(vless_share_link 203.0.113.8 443 uuid-1 www.microsoft.com pubk abcd)"
assert_file_contains <(printf '%s\n' "$vless") "vless://uuid-1@203.0.113.8:443" "vless link host/port"
assert_file_contains <(printf '%s\n' "$vless") "security=reality" "vless link uses reality"
assert_file_contains <(printf '%s\n' "$vless") "pbk=pubk" "vless link includes public key"

hy2="$(hy2_share_link example.com 8443 'p@ss' www.bing.com)"
assert_file_contains <(printf '%s\n' "$hy2") "hysteria2://p%40ss@example.com:8443" "hy2 password is urlencoded"
assert_file_contains <(printf '%s\n' "$hy2") "insecure=1" "hy2 marks self-signed cert"

# JSON renderer
UUID="11111111-1111-1111-1111-111111111111"
TUIC_UUID="22222222-2222-2222-2222-222222222222"
REALITY_PRIV="priv"
REALITY_PUB="pub"
REALITY_SID="abcd1234"
HY2_PWD="hy2pass"
TUIC_PWD="tuicpass"
SS_KEY="sskey+/="
PORT_VLESS=20001
PORT_HY2=20002
PORT_TUIC=20003
PORT_SS=20004
SB_ALLOW_PRIVATE=0
SB_LISTEN="0.0.0.0"
SB_SNI="www.microsoft.com"
SB_TLS_SNI="www.bing.com"
SB_LOG="/tmp/sb.log"
SB_CERT_DIR="/tmp/cert"
json="$(render_singbox_config)"
printf '%s' "$json" | grep -q '"type": "vless"' || fail "config contains vless"
printf '%s' "$json" | grep -q '"type": "hysteria2"' || fail "config contains hysteria2"
printf '%s' "$json" | grep -q '"type": "tuic"' || fail "config contains tuic"
printf '%s' "$json" | grep -q '"type": "shadowsocks"' || fail "config contains shadowsocks"
printf '%s' "$json" | grep -q '"ip_is_private": true' || fail "default config rejects private"
pass "sing-box config contains four inbounds and private reject"

SB_ALLOW_PRIVATE=1
json_open="$(render_singbox_config)"
printf '%s' "$json_open" | grep -q '"ip_is_private": true' && fail "allow-private should omit reject rule"
pass "allow-private omits private reject rule"

if command -v python >/dev/null 2>&1; then
    printf '%s' "$json" | python -c 'import json,sys; json.load(sys.stdin)' || fail "rendered config is valid JSON"
    pass "rendered config is valid JSON"
elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "rendered config is valid JSON"
    pass "rendered config is valid JSON"
elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq empty || fail "rendered config is valid JSON"
    pass "rendered config is valid JSON"
else
    pass "skip JSON parse (no python/jq)"
fi

# --- socks wrapper path ---
socks_path="$(socks_script_path)"
[[ -f "$socks_path" ]] || fail "socks alpine script is missing: $socks_path"
pass "socks wrapper points at existing alpine script"

# --- syntax check ---
syntax_fail=0
while IFS= read -r script; do
    if ! bash -n "$script"; then
        echo "syntax error: $script" >&2
        syntax_fail=1
    fi
done < <(find "$ROOT_DIR" -type f -name '*.sh' ! -path '*/.git/*')
((syntax_fail == 0)) || fail "all shell scripts parse"
pass "all shell scripts parse (bash -n)"

printf '\n%s tests passed\n' "$pass_count"
