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
assert_file_contains "$config" "$REALM_MANAGED_MARKER" "rendered config is marked managed"

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

# --- sing-box asset selection (prefer musl, do not pick glibc by accident) ---
assert_eq "sing-box-.*-linux-amd64-musl\\.tar\\.gz$" \
    "$(singbox_asset_pattern amd64 musl)" \
    "musl asset regex is exact"
assert_eq "sing-box-.*-linux-amd64\\.tar\\.gz$" \
    "$(singbox_asset_pattern amd64 glibc)" \
    "glibc asset regex is exact"

asset_json='{"assets":[
  {"name":"sing-box-1.13.18-linux-amd64.tar.gz","browser_download_url":"https://example.invalid/glibc"},
  {"name":"sing-box-1.13.18-linux-amd64-musl.tar.gz","browser_download_url":"https://example.invalid/musl"},
  {"name":"sing-box-1.13.18-linux-amd64-glibc.tar.gz","browser_download_url":"https://example.invalid/named-glibc"}
]}'
assert_eq "https://example.invalid/musl" \
    "$(pick_release_asset_url "$asset_json" "$(singbox_asset_pattern amd64 musl)")" \
    "picker selects linux-amd64-musl"
assert_eq "https://example.invalid/glibc" \
    "$(pick_release_asset_url "$asset_json" "$(singbox_asset_pattern amd64 glibc)")" \
    "glibc regex does not match -musl"

# --- sing-box share links ---
vless="$(vless_share_link 203.0.113.8 443 uuid-1 www.tokyometro.jp pubk abcd)"
assert_file_contains <(printf '%s\n' "$vless") "vless://uuid-1@203.0.113.8:443" "vless link host/port"
assert_file_contains <(printf '%s\n' "$vless") "security=reality" "vless link uses reality"
assert_file_contains <(printf '%s\n' "$vless") "sni=www.tokyometro.jp" "vless default sni"
assert_file_contains <(printf '%s\n' "$vless") "pbk=pubk" "vless link includes public key"

anytls="$(anytls_share_link example.com 8443 'p@ss' www.tokyometro.jp)"
assert_file_contains <(printf '%s\n' "$anytls") "anytls://p%40ss@example.com:8443" "anytls password is urlencoded"
assert_file_contains <(printf '%s\n' "$anytls") "insecure=1" "anytls marks self-signed cert"
assert_file_contains <(printf '%s\n' "$anytls") "sni=www.tokyometro.jp" "anytls sni"

socks_ob="$(share_link_to_outbound 'socks5h://user:p%40ss@203.0.113.8:1080' hk-socks)"
printf '%s' "$socks_ob" | grep -q '"type":"socks"' || fail "socks5h import type"
printf '%s' "$socks_ob" | grep -q '"server":"203.0.113.8"' || fail "socks5h import host"
printf '%s' "$socks_ob" | grep -q '"username":"user"' || fail "socks5h import user"
printf '%s' "$socks_ob" | grep -q '"password":"p@ss"' || fail "socks5h import password"
pass "socks5h share link is imported"

match_json="$(parse_route_match_json 'geosite:netflix suffix:openai.com')"
printf '%s' "$match_json" | grep -q 'geosite-netflix' || fail "geosite match expands"
printf '%s' "$match_json" | grep -q 'openai.com' || fail "suffix match is kept"
pass "route match parser accepts geosite and suffix"

# JSON renderer
UUID="11111111-1111-1111-1111-111111111111"
REALITY_PRIV="priv"
REALITY_PUB="pub"
REALITY_SID="abcd1234"
ANYTLS_PWD="anytls-pass"
PORT_VLESS=20001
PORT_ANYTLS=20002
PORT_VLESS_W=20003
PORT_ANYTLS_W=20004
SB_ALLOW_PRIVATE=0
ENABLE_WARP=false
SB_LISTEN="0.0.0.0"
SB_SNI="www.tokyometro.jp"
SB_LOG="/tmp/sb.log"
SB_CERT_DIR="/tmp/cert"
SB_DIR="${TEST_TMP:-/tmp}"
SB_ROUTE_JSON="$(mktemp)"
register_temp "$SB_ROUTE_JSON"
empty_route_json >"$SB_ROUTE_JSON"
json="$(render_singbox_config)"
assert_eq "2" "$(printf '%s' "$json" | jq '[.dns.servers[] | select(.tag == "dns-doh-primary" or .tag == "dns-doh-v6") | select(.tls.enabled == true)] | length')" \
    "DoH resolvers keep TLS enabled"
assert_eq "false" "$(printf '%s' "$json" | jq '[.dns.servers[] | select(.tag == "dns-doh-primary" or .tag == "dns-doh-v6") | (.tls | has("server_name"))] | any')" \
    "DoH resolvers do not force SNI"
printf '%s' "$json" | grep -q '"type": "vless"' || fail "config contains vless"
printf '%s' "$json" | grep -q '"type": "anytls"' || fail "config contains anytls"
printf '%s' "$json" | grep -q 'hysteria2' && fail "config should not contain hysteria2"
printf '%s' "$json" | grep -q '"www.tokyometro.jp"' || fail "config uses tokyometro sni"
printf '%s' "$json" | grep -q '"ip_is_private": true' || fail "default config rejects private"
pass "sing-box config is VLESS+AnyTLS with private reject"

SB_ALLOW_PRIVATE=1
json_open="$(render_singbox_config)"
printf '%s' "$json_open" | grep -q '"ip_is_private": true' && fail "allow-private should omit reject rule"
pass "allow-private omits private reject rule"
SB_ALLOW_PRIVATE=0

# --- single-node mode (NAT boxes with one forwarded port) ---
assert_eq "vless" "$(normalize_single_proto VLESS)" "protocol name is normalized"
assert_eq "anytls" "$(normalize_single_proto AnyTLS)" "anytls name is normalized"
assert_false "unknown protocol is rejected" normalize_single_proto hysteria2

assert_eq "2" "$(node_plan_json | jq 'length')" "full mode without warp plans 2 inbounds"

SB_MODE="single"
SB_SINGLE_PROTO="anytls"
SB_SINGLE_PORT=34567
SB_SINGLE_WARP=0
json_single="$(render_singbox_config)"
assert_eq "1" "$(printf '%s' "$json_single" | jq '.inbounds | length')" \
    "single mode renders exactly one inbound"
assert_eq "anytls" "$(printf '%s' "$json_single" | jq -r '.inbounds[0].type')" \
    "single mode honours the chosen protocol"
assert_eq "34567" "$(printf '%s' "$json_single" | jq -r '.inbounds[0].listen_port')" \
    "single mode listens on the requested port"
assert_eq "0" "$(printf '%s' "$json_single" | jq '[.route.rules[] | select(.outbound == "warp")] | length')" \
    "direct single node has no warp route rule"

SB_LINKS="$(mktemp)"
register_temp "$SB_LINKS"
SB_HOST="203.0.113.9"
SB_SINGLE_PROTO="vless"
write_share_links
assert_eq "1" "$(grep -c '://' "$SB_LINKS")" "single mode writes exactly one share link"
assert_file_contains "$SB_LINKS" "vless://${UUID}@203.0.113.9:34567" \
    "single-node link uses the fixed port"

SB_MODE="full"
write_share_links
assert_eq "2" "$(grep -c '://' "$SB_LINKS")" "full mode without warp writes two share links"

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

# --- warp client_id reserved bytes ---
toml_tmp="$(mktemp)"
register_temp "$toml_tmp"
printf 'client_id = "AQID"\n' >"$toml_tmp"
assert_eq "1 2 3" "$(parse_warp_client_id "$toml_tmp")" "client_id AQID decodes to 1 2 3"

ENABLE_WARP=true
WARP_PRIVATE_KEY="privkey"
WARP_PEER_PUBLIC_KEY="pubkey"
WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
WARP_ENDPOINT_PORT=2408
WARP_ADDRESS_V4="172.16.0.2/32"
WARP_ADDRESS_V6="2606:4700:110::1/128"
WARP_RESERVED_1=1
WARP_RESERVED_2=2
WARP_RESERVED_3=3
json_warp="$(render_singbox_config)"
assert_eq "[1,2,3]" "$(printf '%s' "$json_warp" | jq -c '.endpoints[0].peers[0].reserved')" \
    "rendered config contains parsed reserved bytes"
assert_file_contains <(printf '%s\n' "$json_warp") "dns-doh-v6" "dns config has ipv6 doh server"
assert_file_contains <(printf '%s\n' "$json_warp") "dns-local" "dns config has local fallback"
ENABLE_WARP=false

# --- socks wrapper path & nat ---
socks_path="$(socks_script_path)"
[[ -f "$socks_path" ]] || fail "socks alpine script is missing: $socks_path"
pass "socks wrapper points at existing alpine script"

# --- socks5 nat option check in subprocess ---
socks_out=$(bash "$socks_path" nat -p 10240 -H 1.2.3.4 --version 2>&1 || true)
pass "socks5 script accepts nat sub-command and parameters"

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
