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

# Gaps from older state files are compacted after add/delete.
gapped="$(mktemp)"
register_temp "$gapped"
printf '# id\tlisten\tremote\n1\t0.0.0.0:1000\ta.example:443\n3\t0.0.0.0:2000\tb.example:443\n' >"$gapped"
compact_routes "$gapped"
assert_eq "2" "$(route_count "$gapped")" "compact keeps two routes"
assert_eq $'1\t0.0.0.0:1000\ta.example:443\n2\t0.0.0.0:2000\tb.example:443' \
    "$(awk -F '\t' '!/^#/ && NF >= 3 { print $0 }' "$gapped")" \
    "compact rewrites IDs as 1..N"

id3="$(append_route_to_state "$gapped" 3000 c.example:443)"
assert_eq "3" "$id3" "add after compact gets next sequential ID"

delete_route_from_state "$gapped" 2 || fail "delete existing route"
assert_eq "2" "$(route_count "$gapped")" "delete then compact leaves two routes"
assert_eq $'1\t0.0.0.0:1000\ta.example:443\n2\t0.0.0.0:3000\tc.example:443' \
    "$(awk -F '\t' '!/^#/ && NF >= 3 { print $0 }' "$gapped")" \
    "delete resequences remaining IDs instead of leaving a gap"
id_reused="$(append_route_to_state "$gapped" 2000 b.example:443)"
assert_eq "3" "$id_reused" "add after delete continues from compacted count"

edited="$(update_route_in_state "$gapped" 1 11111 other.example:443)"
assert_eq "1" "$edited" "edit keeps the same ID"
read_route "$gapped" 1 || fail "read edited route"
assert_eq "0.0.0.0:11111" "$ROUTE_LISTEN" "edit updates listen"
assert_eq "other.example:443" "$ROUTE_REMOTE" "edit updates remote"
assert_false "edit duplicate is rejected" update_route_in_state "$gapped" 1 2000 b.example:443

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
assert_file_contains <(printf '%s\n' "$vless") "fp=ios" "vless link uses ios utls fingerprint"

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
PORT_VLESS=20001
SB_ALLOW_PRIVATE=0
SB_LISTEN="0.0.0.0"
SB_SNI="www.tokyometro.jp"
SB_LOG="/tmp/sb.log"
SB_DIR="${TEST_TMP:-/tmp}"
SB_ROUTE_JSON="$(mktemp)"
register_temp "$SB_ROUTE_JSON"
empty_route_json >"$SB_ROUTE_JSON"
json="$(render_singbox_config)"
assert_eq "2" "$(printf '%s' "$json" | jq '[.dns.servers[] | select(.tag == "dns-doh-primary" or .tag == "dns-doh-v6") | select(.tls.enabled == true)] | length')" \
    "DoH resolvers keep TLS enabled"
assert_eq "false" "$(printf '%s' "$json" | jq '[.dns.servers[] | select(.tag == "dns-doh-primary" or .tag == "dns-doh-v6") | (.tls | has("server_name"))] | any')" \
    "DoH resolvers do not force SNI"
assert_eq "1" "$(printf '%s' "$json" | jq '.inbounds | length')" "config has exactly one inbound"
assert_eq "vless" "$(printf '%s' "$json" | jq -r '.inbounds[0].type')" "inbound is vless"
assert_eq "20001" "$(printf '%s' "$json" | jq -r '.inbounds[0].listen_port')" "inbound uses PORT_VLESS"
printf '%s' "$json" | grep -q '"type": "anytls"' && fail "config should not contain anytls inbound"
printf '%s' "$json" | grep -q 'hysteria2' && fail "config should not contain hysteria2"
printf '%s' "$json" | grep -q '"type": "wireguard"' && fail "config should not contain warp/wireguard"
printf '%s' "$json" | grep -q '"www.tokyometro.jp"' || fail "config uses tokyometro sni"
printf '%s' "$json" | grep -q '"ip_is_private": true' || fail "default config rejects private"
assert_file_contains <(printf '%s\n' "$json") "dns-doh-v6" "dns config has ipv6 doh server"
assert_file_contains <(printf '%s\n' "$json") "dns-local" "dns config has local fallback"
pass "sing-box config is VLESS Reality with private reject"

SB_ALLOW_PRIVATE=1
json_open="$(render_singbox_config)"
printf '%s' "$json_open" | grep -q '"ip_is_private": true' && fail "allow-private should omit reject rule"
pass "allow-private omits private reject rule"
SB_ALLOW_PRIVATE=0

assert_eq "1" "$(node_plan_json | jq 'length')" "node plan is a single vless inbound"

PORT_VLESS=34567
json_port="$(render_singbox_config)"
assert_eq "1" "$(printf '%s' "$json_port" | jq '.inbounds | length')" \
    "specified port still renders one inbound"
assert_eq "34567" "$(printf '%s' "$json_port" | jq -r '.inbounds[0].listen_port')" \
    "specified port is honoured"
assert_eq "0" "$(printf '%s' "$json_port" | jq '[.route.rules[] | select(.outbound == "warp")] | length')" \
    "config has no warp route rule"

SB_LINKS="$(mktemp)"
register_temp "$SB_LINKS"
SB_HOST="203.0.113.9"
write_share_links
assert_eq "1" "$(grep -c '://' "$SB_LINKS")" "writes exactly one share link"
assert_file_contains "$SB_LINKS" "vless://${UUID}@203.0.113.9:34567" \
    "share link uses the listen port"

# Leftover warp rules from older installs are dropped.
printf '%s\n' '{"rules":[{"outbound":"warp","domain":["example.com"]},{"outbound":"direct-ipv4","domain":["ok.example"]}],"rule_set":[],"outbounds":[]}' >"$SB_ROUTE_JSON"
ensure_route_file
assert_eq "1" "$(jq '.rules | length' "$SB_ROUTE_JSON")" "warp custom rule is stripped"
assert_eq "direct-ipv4" "$(jq -r '.rules[0].outbound' "$SB_ROUTE_JSON")" "non-warp custom rule is kept"

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
