#!/usr/bin/env bash
# Alpine sing-box: VLESS Reality inbound, custom routes.
# Adapted from sing-box-plus for OpenRC / musl.

if [[ -z "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

SB_VERSION_LABEL="1.2.0"
SB_GITHUB_REPO="SagerNet/sing-box"
SB_DIR="${SB_DIR:-/opt/alpine-sing-box}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_CONF="${SB_CONF:-${SB_DIR}/config.json}"
SB_STATE="${SB_STATE:-${SB_DIR}/state.env}"
SB_LINKS="${SB_LINKS:-${SB_DIR}/share-links.txt}"
SB_DATA_DIR="${SB_DATA_DIR:-${SB_DIR}/data}"
SB_ROUTE_JSON="${SB_ROUTE_JSON:-${SB_DIR}/routes.json}"
SB_SERVICE="${SB_SERVICE:-alpine-sing-box}"
SB_INIT="/etc/init.d/${SB_SERVICE}"
SB_LOG="${SB_LOG:-/var/log/alpine-sing-box.log}"
SB_USER="${SB_USER:-sing-box}"
SB_MANAGED_MARKER="# Managed by alpine-optimize sing-box"

SB_HOST="${SB_HOST:-}"
SB_SNI="${SB_SNI:-www.tokyometro.jp}"
SB_TAG="${SB_TAG:-latest}"
SB_ALLOW_PRIVATE="${SB_ALLOW_PRIVATE:-0}"
SB_LISTEN="${SB_LISTEN:-}"
PORT_VLESS="${PORT_VLESS:-}"

CLI_FORCE=0
CLI_PORT=""
SB_DID_MIGRATE=0
STATE_VERSION=""
SBP_PARSED_HOST=""
SBP_PARSED_PORT=""
SBP_SELECTED_OUTBOUND=""

default_listen_address() {
    if [[ -n "$SB_LISTEN" ]]; then
        printf '%s\n' "$SB_LISTEN"
        return
    fi
    if [[ -e /proc/net/if_inet6 ]] \
        && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" != "1" ]]; then
        printf '::\n'
    else
        printf '0.0.0.0\n'
    fi
}

singbox_usage() {
    cat <<'EOF'
Alpine sing-box（OpenRC）

入站：一条 VLESS Reality。支持自定义分流，以及导入
socks5h / 分享链接作为远程出口。NAT 机型可用 --port 指定映射端口。

用法：
  alpine.sh sing-box                  交互菜单（停留在子菜单）
  alpine.sh sing-box install [选项]
  alpine.sh sing-box single           交互式指定端口（NAT）
  alpine.sh sing-box links
  alpine.sh sing-box status
  alpine.sh sing-box restart
  alpine.sh sing-box routes
  alpine.sh sing-box edit
  alpine.sh sing-box update [--version TAG]
  alpine.sh sing-box uninstall [--purge] [--yes]

install 选项：
  -H, --host HOST          客户端连接地址（IPv4 或域名）
      --sni HOST           Reality SNI，默认 www.tokyometro.jp
      --version TAG        指定 sing-box 版本
      --allow-private      允许代理访问内网地址
  -p, --port PORT          监听端口，留空随机
  -f, --force              覆盖已有安装

已安装时再次执行 install 并带上 --port，会就地改端口并保留
原有 UUID 与 Reality 密钥。
EOF
}

singbox_prepare() {
    require_root
    require_alpine
    require_openrc
    enable_community_repo
    ensure_packages curl ca-certificates tar jq openssl coreutils iproute2 shadow libcap
}

urldec() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

b64dec() {
    local s="$1" pad
    s="${s//-/+}"; s="${s//_/\/}"
    pad=$(( (4 - ${#s} % 4) % 4 ))
    while ((pad > 0)); do s+="="; pad=$((pad - 1)); done
    printf '%s' "$s" | openssl base64 -d -A 2>/dev/null || printf '%s' "$s" | base64 -d 2>/dev/null
}

query_get() {
    local query="$1" key="$2" pair k v
    local -a pairs
    [[ -n "$query" ]] || return 0
    IFS='&' read -r -a pairs <<<"$query"
    for pair in "${pairs[@]}"; do
        k="${pair%%=*}"
        v="${pair#*=}"
        [[ "$(urldec "$k")" == "$key" ]] || continue
        urldec "$v"
        return 0
    done
}

split_hostport() {
    local hostport="$1"
    SBP_PARSED_HOST=""; SBP_PARSED_PORT=""
    if [[ "$hostport" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        SBP_PARSED_HOST="${BASH_REMATCH[1]}"
        SBP_PARSED_PORT="${BASH_REMATCH[2]}"
    elif [[ "$hostport" == *:* ]]; then
        SBP_PARSED_HOST="${hostport%:*}"
        SBP_PARSED_PORT="${hostport##*:}"
    else
        return 1
    fi
    [[ "$SBP_PARSED_PORT" =~ ^[0-9]+$ ]]
}

urlencode() {
    local raw="$1"
    local i c out=""
    local LC_ALL=C
    for ((i = 0; i < ${#raw}; i++)); do
        c="${raw:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v out '%s%%%02X' "$out" "'$c" ;;
        esac
    done
    printf '%s\n' "$out"
}

generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
    else
        printf '%s-%s-%s-%s-%s\n' "$(random_hex 8)" "$(random_hex 4)" "$(random_hex 4)" "$(random_hex 4)" "$(random_hex 12)"
    fi
}

# Single source of truth for the inbound: {proto, tag, port}.
node_plan_json() {
    jq -n -c --argjson port "${PORT_VLESS:-0}" \
        '[{proto:"vless", tag:"vless-reality", port:$port}]'
}

parse_reality_keypair() {
    local output="$1"
    REALITY_PRIV="$(awk -F': ' '/[Pp]rivate/{print $2}' <<<"$output" | tr -d '[:space:]')"
    REALITY_PUB="$(awk -F': ' '/[Pp]ublic/{print $2}' <<<"$output" | tr -d '[:space:]')"
    [[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]]
}

host_is_musl() {
    is_alpine && return 0
    compgen -G '/lib/ld-musl-*.so*' >/dev/null && return 0
    { ldd --version 2>&1 || true; } | grep -qi musl
}

singbox_asset_pattern() {
    local goarch="$1"
    local variant="${2:-auto}"
    case "$variant" in
        musl) printf 'sing-box-.*-linux-%s-musl\\.tar\\.gz$\n' "$goarch" ;;
        glibc) printf 'sing-box-.*-linux-%s\\.tar\\.gz$\n' "$goarch" ;;
        *) die "未知 sing-box 资产类型：${variant}" ;;
    esac
}

pick_release_asset_url() {
    local json="$1"
    local pattern="$2"
    printf '%s' "$json" | jq -r --arg p "$pattern" '
        .assets[]? | select(.name | test($p)) | .browser_download_url
    ' | awk 'NF && $0 != "null" { print; exit }'
}

singbox_probe() {
    local bin="$1"
    local output
    [[ -x "$bin" ]] || return 1
    output="$("$bin" version 2>&1)" || {
        warn "二进制无法执行：${output:-not found / loader error}"
        return 1
    }
    return 0
}

install_singbox_from_apk() {
    local apk_bin=""
    enable_community_repo
    info "GitHub 二进制不兼容当前 musl 系统，改用 Alpine 软件包。"
    apk_add sing-box || return 1
    if command_exists sing-box; then
        apk_bin="$(command -v sing-box)"
    elif [[ -x /usr/bin/sing-box ]]; then
        apk_bin="/usr/bin/sing-box"
    else
        return 1
    fi
    install -d -m 0755 "$(dirname "$SB_BIN")"
    ln -sfn "$apk_bin" "$SB_BIN"
    service_stop sing-box 2>/dev/null || true
    service_disable sing-box 2>/dev/null || true
    singbox_probe "$SB_BIN"
}

download_singbox() {
    local requested="${1:-latest}"
    local goarch tmp json url tag archive extracted label pattern
    local -a patterns=()

    goarch="$(detect_goarch)"
    tmp="$(new_temp_dir)"

    if [[ "$requested" == "latest" ]]; then
        json="$(curl -fsSL --retry 3 --connect-timeout 15 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: alpine-optimize-sing-box' \
            "https://api.github.com/repos/${SB_GITHUB_REPO}/releases/latest")" \
            || die "无法获取 sing-box 发布信息。"
    else
        [[ "$requested" == v* ]] || requested="v${requested}"
        json="$(curl -fsSL --retry 3 --connect-timeout 15 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: alpine-optimize-sing-box' \
            "https://api.github.com/repos/${SB_GITHUB_REPO}/releases/tags/${requested}")" \
            || die "无法获取 sing-box ${requested}。"
    fi

    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
    [[ -n "$tag" ]] || die "发布信息中缺少版本号。"

    if host_is_musl; then
        patterns+=("$(singbox_asset_pattern "$goarch" musl)")
    fi
    patterns+=("$(singbox_asset_pattern "$goarch" glibc)")

    url=""; label=""
    for pattern in "${patterns[@]}"; do
        url="$(pick_release_asset_url "$json" "$pattern")"
        if [[ -n "$url" ]]; then
            if [[ "$pattern" == *-musl* ]]; then
                label="linux-${goarch}-musl"
            else
                label="linux-${goarch}"
            fi
            break
        fi
    done
    [[ -n "$url" ]] || die "未找到 linux-${goarch} 发布包。"

    archive="${tmp}/sing-box.tar.gz"
    info "下载 sing-box ${tag}（${label}）..."
    curl -fsSL --retry 3 --connect-timeout 15 -o "$archive" "$url" || die "sing-box 下载失败。"
    tar -xzf "$archive" -C "$tmp"
    extracted="$(find "$tmp" -type f -name sing-box -print -quit)"
    [[ -n "$extracted" ]] || die "发布包中未找到 sing-box。"
    install -d -m 0755 "$(dirname "$SB_BIN")"
    install -m 0755 "$extracted" "$SB_BIN"
    if command_exists setcap; then
        setcap cap_net_bind_service=+ep "$SB_BIN" 2>/dev/null || true
    fi

    if singbox_probe "$SB_BIN"; then
        ok "已安装 sing-box ${tag} -> ${SB_BIN}"
        return 0
    fi
    if host_is_musl && install_singbox_from_apk; then
        ok "已通过 apk 安装 sing-box -> ${SB_BIN}"
        return 0
    fi
    die "下载的 sing-box 无法在当前系统运行。Alpine 请使用官方 linux-${goarch}-musl 包。"
}

ensure_singbox_binary() {
    local version="${1:-${SB_TAG:-latest}}"
    if [[ ! -x "$SB_BIN" ]] || ! singbox_probe "$SB_BIN" >/dev/null 2>&1; then
        download_singbox "$version"
    fi
}

empty_route_json() { printf '%s\n' '{"rules":[],"rule_set":[],"outbounds":[]}'; }

ensure_route_file() {
    mkdir -p "$SB_DIR"
    if [[ ! -s "$SB_ROUTE_JSON" ]]; then
        empty_route_json >"$SB_ROUTE_JSON"
        return 0
    fi
    if ! jq -e 'type == "object"' "$SB_ROUTE_JSON" >/dev/null 2>&1; then
        mv "$SB_ROUTE_JSON" "${SB_ROUTE_JSON}.bad.$(date +%Y%m%d-%H%M%S)"
        warn "自定义路由文件无效，已重建。"
        empty_route_json >"$SB_ROUTE_JSON"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    # Drop leftover warp rules from older installs.
    jq -c '
        .rules = ((.rules // []) | map(select((.outbound // "") != "warp")))
        | .rule_set = (.rule_set // [])
        | .outbounds = ((.outbounds // []) | map(select((.tag // "") != "warp")))
    ' "$SB_ROUTE_JSON" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SB_ROUTE_JSON"
}

load_route_json() {
    ensure_route_file
    jq -c '.rules = (.rules // []) | .rule_set = (.rule_set // []) | .outbounds = (.outbounds // [])' "$SB_ROUTE_JSON"
}

valid_route_tag() { [[ "${1:-}" =~ ^[A-Za-z0-9._@!-]+$ ]]; }

default_ipv4_address() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

default_ipv6_address() {
    ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

parse_route_match_json() {
    local raw="$1" token key value code tag url json
    json='{"domain":[],"domain_suffix":[],"domain_keyword":[],"domain_regex":[],"rule_set":[],"rule_set_defs":[]}'
    raw="${raw//$'\r'/ }"
    raw="${raw//$'\n'/ }"
    raw="${raw//,/ }"
    local -a tokens=()
    local oldifs=$IFS
    IFS=$' \t'
    read -r -a tokens <<<"$raw"
    IFS=$oldifs
    for token in "${tokens[@]}"; do
        [[ -n "$token" ]] || continue
        value="$token"
        case "$token" in
            geosite:*|site:*) key="geosite"; value="${token#*:}" ;;
            domain:*) key="domain"; value="${token#*:}" ;;
            suffix:*) key="suffix"; value="${token#*:}" ;;
            keyword:*) key="keyword"; value="${token#*:}" ;;
            regex:*) key="regex"; value="${token#*:}" ;;
            *.*) key="suffix" ;;
            *) key="geosite" ;;
        esac
        [[ -n "$value" ]] || continue
        case "$key" in
            geosite)
                code="$value"
                valid_route_tag "$code" || continue
                tag="geosite-${code}"
                url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${tag}.srs"
                json="$(printf '%s' "$json" | jq -c --arg tag "$tag" --arg url "$url" '
                    .rule_set += [$tag]
                    | .rule_set = (.rule_set | unique)
                    | .rule_set_defs += [{type:"remote", tag:$tag, format:"binary", url:$url, download_detour:"direct", update_interval:"1d"}]
                    | .rule_set_defs = (.rule_set_defs | unique_by(.tag))')"
                ;;
            domain)
                json="$(printf '%s' "$json" | jq -c --arg v "$value" '.domain += [$v] | .domain = (.domain | unique)')" ;;
            suffix)
                json="$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_suffix += [$v] | .domain_suffix = (.domain_suffix | unique)')" ;;
            keyword)
                json="$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_keyword += [$v] | .domain_keyword = (.domain_keyword | unique)')" ;;
            regex)
                json="$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_regex += [$v] | .domain_regex = (.domain_regex | unique)')" ;;
        esac
    done
    printf '%s' "$json" | jq -c 'with_entries(select((.key == "rule_set_defs") or ((.value | type) != "array") or ((.value | length) > 0)))'
}

share_link_to_outbound() {
    local link="$1" tag="$2" scheme rest body query userinfo hostport server port
    local sni fp insecure allow username password ver
    link="${link//$'\r'/}"
    link="${link//$'\n'/}"
    scheme="${link%%://*}"
    [[ "$scheme" != "$link" ]] || return 1
    rest="${link#*://}"
    body="${rest%%\#*}"
    query=""
    if [[ "$body" == *"?"* ]]; then
        query="${body#*\?}"
        body="${body%%\?*}"
    fi

    case "$scheme" in
        vless|anytls|socks|socks5|socks5h|socks4|socks4a|http|https)
            ;;
        *) return 1 ;;
    esac

    case "$scheme" in
        vless)
            [[ "$body" == *"@"* ]] || return 1
            userinfo="${body%@*}"; hostport="${body##*@}"
            split_hostport "$hostport" || return 1
            server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
            local uuid flow security pbk sid
            uuid="$(urldec "$userinfo")"
            flow="$(query_get "$query" flow)"
            security="$(query_get "$query" security)"
            sni="$(query_get "$query" sni)"
            fp="$(query_get "$query" fp)"
            pbk="$(query_get "$query" pbk)"
            sid="$(query_get "$query" sid)"
            jq -n -c \
                --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
                --arg flow "$flow" --arg security "$security" --arg sni "$sni" --arg fp "${fp:-ios}" \
                --arg pbk "$pbk" --arg sid "$sid" '
                {type:"vless", tag:$tag, server:$server, server_port:$port, uuid:$uuid, domain_resolver:"dns-doh-primary"}
                | if $flow != "" then .flow = $flow else . end
                | if $security == "reality" then
                    .tls = {enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp}, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
                  elif $security == "tls" then
                    .tls = ({enabled:true} | if $sni != "" then .server_name = $sni else . end)
                  else . end'
            ;;
        anytls)
            [[ "$body" == *"@"* ]] || return 1
            userinfo="${body%@*}"; hostport="${body##*@}"
            split_hostport "$hostport" || return 1
            server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
            password="$(urldec "$userinfo")"
            sni="$(query_get "$query" sni)"
            insecure="$(query_get "$query" insecure)"
            allow="$(query_get "$query" allowInsecure)"
            [[ "$insecure" == "1" || "$allow" == "1" ]] && insecure=true || insecure=false
            jq -n -c \
                --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" '
                {type:"anytls", tag:$tag, server:$server, server_port:$port, password:$password,
                 tls:({enabled:true, alpn:["h2","http/1.1"]}
                    | if $sni != "" then .server_name = $sni else . end
                    | if $insecure then .insecure = true else . end),
                 domain_resolver:"dns-doh-primary"}'
            ;;
        socks|socks5|socks5h|socks4|socks4a)
            ver="5"
            [[ "$scheme" == "socks4" || "$scheme" == "socks4a" ]] && ver="4"
            username=""; password=""
            if [[ "$body" == *"@"* ]]; then
                userinfo="${body%@*}"; hostport="${body##*@}"
                if [[ "$userinfo" == *:* ]]; then
                    username="$(urldec "${userinfo%%:*}")"
                    password="$(urldec "${userinfo#*:}")"
                else
                    username="$(urldec "$userinfo")"
                fi
            else
                hostport="$body"
            fi
            split_hostport "$hostport" || return 1
            server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
            jq -n -c \
                --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg user "$username" --arg pass "$password" --arg ver "$ver" '
                {type:"socks", tag:$tag, server:$server, server_port:$port, version:$ver, domain_resolver:"dns-doh-primary"}
                | if $user != "" then .username = $user else . end
                | if $pass != "" then .password = $pass else . end'
            ;;
        http|https)
            username=""; password=""
            if [[ "$body" == *"@"* ]]; then
                userinfo="${body%@*}"; hostport="${body##*@}"
                if [[ "$userinfo" == *:* ]]; then
                    username="$(urldec "${userinfo%%:*}")"
                    password="$(urldec "${userinfo#*:}")"
                else
                    username="$(urldec "$userinfo")"
                fi
            else
                hostport="$body"
            fi
            split_hostport "$hostport" || return 1
            server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
            jq -n -c \
                --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg user "$username" --arg pass "$password" --argjson https "$([[ "$scheme" == "https" ]] && echo true || echo false)" '
                {type:"http", tag:$tag, server:$server, server_port:$port, domain_resolver:"dns-doh-primary"}
                | if $user != "" then .username = $user else . end
                | if $pass != "" then .password = $pass else . end
                | if $https then .tls = {enabled:true} else . end'
            ;;
        *) return 1 ;;
    esac
}

render_singbox_config() {
    local listen routes nodes
    listen="$(default_listen_address)"
    routes="$(load_route_json)"
    nodes="$(node_plan_json)"

    local dns_strategy="prefer_ipv4"
    if [[ -z "$(default_ipv4_address || true)" && -n "$(default_ipv6_address || true)" ]]; then
        dns_strategy="prefer_ipv6"
    fi

    # The resolver certificates cover their literal IPs; forced hostname SNI is
    # reset by some NAT egress paths even though IP-based TLS verification works.
    jq -n \
        --arg LOG "$SB_LOG" --arg LISTEN "$listen" --arg SNI "$SB_SNI" \
        --arg UUID "$UUID" --arg RPRIV "$REALITY_PRIV" --arg RSID "$REALITY_SID" \
        --argjson NODES "$nodes" \
        --argjson PRIV "$SB_ALLOW_PRIVATE" \
        --argjson CUSTOM "$routes" \
        --arg STRATEGY "$dns_strategy" \
        --arg BIND4 "$(default_ipv4_address || true)" --arg BIND6 "$(default_ipv6_address || true)" '
        def inbound_vless($port; $tag):
          {type:"vless", tag:$tag, listen:$LISTEN, listen_port:$port,
           users:[{uuid:$UUID, flow:"xtls-rprx-vision"}],
           tls:{enabled:true, server_name:$SNI,
                reality:{enabled:true, handshake:{server:$SNI, server_port:443},
                         private_key:$RPRIV, short_id:[$RSID]}}};
        def custom_rule($rule):
          ({}
            + (if (($rule.domain // [])|length)>0 then {domain:$rule.domain} else {} end)
            + (if (($rule.domain_suffix // [])|length)>0 then {domain_suffix:$rule.domain_suffix} else {} end)
            + (if (($rule.domain_keyword // [])|length)>0 then {domain_keyword:$rule.domain_keyword} else {} end)
            + (if (($rule.domain_regex // [])|length)>0 then {domain_regex:$rule.domain_regex} else {} end)
            + (if (($rule.rule_set // [])|length)>0 then {rule_set:$rule.rule_set} else {} end)
            + {action:"route", outbound:$rule.outbound});
        def uses($tag):
          ((($CUSTOM.rules // []) | map(select((.outbound // "") == $tag)) | length) > 0);
        {
          log:{level:"warn", timestamp:true, output:$LOG},
          dns:{
            servers:[
              {type:"https", tag:"dns-doh-primary", server:"1.1.1.1", path:"/dns-query",
               tls:{enabled:true}},
              {type:"https", tag:"dns-doh-v6", server:"2606:4700:4700::1111", path:"/dns-query",
               tls:{enabled:true}},
              {type:"udp", tag:"dns-udp-fallback", server:"1.0.0.1"},
              {type:"udp", tag:"dns-udp-v6-fallback", server:"2606:4700:4700::1001"},
              {type:"local", tag:"dns-local"}
            ],
            final:"dns-doh-primary",
            strategy:$STRATEGY
          },
          inbounds: ($NODES | map(inbound_vless(.port; .tag))),
          outbounds: (
            [{type:"direct", tag:"direct", domain_resolver:"dns-doh-primary"}]
            + (if uses("direct-ipv4") then
                [{type:"direct", tag:"direct-ipv4",
                  domain_resolver:{server:"dns-doh-primary", strategy:"ipv4_only"}}
                 + (if $BIND4 != "" then {inet4_bind_address:$BIND4, bind_address_no_port:true} else {} end)]
              else [] end)
            + (if uses("direct-ipv6") then
                [{type:"direct", tag:"direct-ipv6",
                  domain_resolver:{server:"dns-doh-primary", strategy:"ipv6_only"}}
                 + (if $BIND6 != "" then {inet6_bind_address:$BIND6, bind_address_no_port:true} else {} end)]
              else [] end)
            + (($CUSTOM.outbounds // []) | map(select((.tag // "") != "" and (.type // "") != "")))
          ),
          route: (
            {
              default_domain_resolver:"dns-doh-primary",
              final:"direct",
              rules: (
                [{action:"sniff"}]
                + (($CUSTOM.rules // []) | map(select((.outbound // "") != "")) | map(custom_rule(.)))
                + (if $PRIV == 0 then [{ip_is_private:true, action:"reject"}] else [] end)
              )
            }
            + (if (($CUSTOM.rule_set // [])|length) > 0 then {rule_set:($CUSTOM.rule_set)} else {} end)
          )
        }'
}

vless_share_link() {
    local host="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" name="${7:-vless-reality}"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=ios&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$uuid" "$host" "$port" "$(urlencode "$sni")" "$pbk" "$sid" "$(urlencode "$name")"
}

write_share_links() {
    local host="${SB_HOST}"
    [[ -n "$host" ]] || host="$(discover_public_ipv4)"
    {
        printf '%s\n' "# VLESS Reality"
        vless_share_link "$host" "${PORT_VLESS}" "$UUID" "$SB_SNI" "$REALITY_PUB" "$REALITY_SID" "vless-reality"
    } >"$SB_LINKS"
    chmod 600 "$SB_LINKS"
}

write_sb_state() {
    write_file "$SB_STATE" 0600 <<EOF
STATE_VERSION=4
SB_HOST=$(printf '%q' "$SB_HOST")
SB_SNI=$(printf '%q' "$SB_SNI")
UUID=$(printf '%q' "$UUID")
REALITY_PRIV=$(printf '%q' "$REALITY_PRIV")
REALITY_PUB=$(printf '%q' "$REALITY_PUB")
REALITY_SID=$(printf '%q' "$REALITY_SID")
PORT_VLESS=$(printf '%q' "${PORT_VLESS:-}")
SB_ALLOW_PRIVATE=$(printf '%q' "$SB_ALLOW_PRIVATE")
INSTALLED_AT=$(printf '%q' "$(iso_now)")
EOF
}

load_sb_state() {
    [[ -f "$SB_STATE" ]] || die "没有找到安装状态：${SB_STATE}"
    # shellcheck disable=SC1090
    source "$SB_STATE"
    migrate_legacy_state
}

migrate_legacy_state() {
    SB_DID_MIGRATE=0
    if [[ "${STATE_VERSION:-1}" == "4" && -n "${PORT_VLESS:-}" ]]; then
        return 0
    fi

    SB_DID_MIGRATE=1
    info "检测到旧版节点布局，正在迁移为单入站 VLESS Reality。"
    if [[ -z "${PORT_VLESS:-}" ]]; then
        if [[ -n "${SB_SINGLE_PORT:-}" ]]; then
            PORT_VLESS="$SB_SINGLE_PORT"
        else
            PORT_VLESS="$(choose_random_port)" || die "无法分配空闲端口。"
        fi
    fi
    if [[ -z "${SB_SNI:-}" || "$SB_SNI" == "www.microsoft.com" || "${SB_TLS_SNI:-}" == "www.bing.com" ]]; then
        SB_SNI="www.tokyometro.jp"
    fi
    STATE_VERSION=4
}

write_sb_init() {
    write_file "$SB_INIT" 0755 <<EOF
#!/sbin/openrc-run
${SB_MANAGED_MARKER}

name="${SB_SERVICE}"
description="Alpine Optimize sing-box"
command="${SB_BIN}"
command_args="run -c ${SB_CONF} -D ${SB_DATA_DIR}"
command_background="yes"
pidfile="/run/${SB_SERVICE}.pid"
command_user="${SB_USER}:${SB_USER}"
output_log="${SB_LOG}"
error_log="${SB_LOG}"
capabilities="^cap_net_bind_service"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 -o ${SB_USER}:${SB_USER} ${SB_DATA_DIR}
    checkpath -f -m 0640 -o ${SB_USER}:${SB_USER} ${SB_LOG}
}
EOF
}

apply_singbox_config() {
    local tmp_conf conf_bak
    ensure_singbox_binary "${SB_TAG:-latest}"
    ensure_system_user "$SB_USER"
    ensure_route_file
    mkdir -p "$SB_DIR" "$SB_DATA_DIR"
    tmp_conf="$(mktemp "${SB_DIR}/config.json.tmp.XXXXXX")"
    register_temp "$tmp_conf"
    render_singbox_config >"$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
    "$SB_BIN" check -c "$tmp_conf" || {
        warn "sing-box 配置校验失败。"
        rm -f "$tmp_conf"
        return 1
    }
    conf_bak=""
    if [[ -f "$SB_CONF" ]]; then
        conf_bak="$(mktemp)"
        cp -a "$SB_CONF" "$conf_bak"
    fi
    install -m 0640 "$tmp_conf" "$SB_CONF"
    chown "${SB_USER}:${SB_USER}" "$SB_CONF" "$SB_DIR" "$SB_DATA_DIR" 2>/dev/null || true
    write_sb_state
    write_share_links
    write_sb_init
    if [[ -x "$SB_INIT" ]]; then
        service_enable "$SB_SERVICE"
        if ! service_restart "$SB_SERVICE"; then
            [[ -n "$conf_bak" ]] && cp -a "$conf_bak" "$SB_CONF"
            rm -f "$conf_bak"
            tail -n 40 "$SB_LOG" >&2 || true
            return 1
        fi
    fi
    rm -f "$conf_bak"
    return 0
}

print_links() {
    [[ -f "$SB_LINKS" ]] || die "尚未安装，或分享链接不存在。"
    if [[ -f "$SB_STATE" ]] && [[ -z "${PORT_VLESS:-}" || -z "${UUID:-}" ]]; then
        load_sb_state
        apply_if_legacy_layout
    fi
    echo
    printf '%ssing-box 分享链接%s\n' "$C_BOLD" "$C_RESET"
    cat "$SB_LINKS"
    echo
    info "完整副本：${SB_LINKS}"
    warn "云安全组 / NAT 映射请放行 TCP ${PORT_VLESS}。"
}

apply_if_legacy_layout() {
    ((SB_DID_MIGRATE == 1)) || return 0
    info "正在按新方案重建配置（单入站 VLESS Reality）..."
    singbox_prepare
    ensure_singbox_binary "${SB_TAG:-latest}"
    apply_singbox_config || die "迁移后启动失败。"
    ok "已迁移到单入站 VLESS Reality。"
}

require_installed() {
    [[ -f "$SB_STATE" ]] || die "尚未安装，请先选择安装。"
    load_sb_state
    apply_if_legacy_layout
    if [[ ! -x "$SB_BIN" ]] || ! service_is_active "$SB_SERVICE"; then
        info "检测到历史配置但程序或服务未就绪，正在恢复..."
        singbox_prepare
        ensure_singbox_binary "${SB_TAG:-latest}"
        apply_singbox_config || die "恢复失败。"
    fi
}

port_is_ours() {
    local port="$1"
    [[ -n "${PORT_VLESS:-}" && "$PORT_VLESS" == "$port" ]]
}

apply_listen_port() {
    local port="${1:-}"
    if [[ -z "$port" ]]; then
        port="$(choose_random_port)" || { warn "无法分配空闲端口。"; return 1; }
    else
        is_valid_port "$port" || { warn "端口无效：${port}"; return 1; }
        port=$((10#$port))
        if ! port_is_ours "$port" && port_in_use "$port"; then
            warn "端口已被占用：${port}"
            return 1
        fi
    fi
    PORT_VLESS="$port"
}

prompt_listen_port() {
    local port=""
    ask port "监听端口（留空随机，NAT 请填已映射的端口）: "
    if [[ -n "$port" ]]; then
        is_valid_port "$port" || { warn "端口无效：${port}"; return 1; }
        printf '%s\n' "$((10#$port))"
    fi
}

singbox_single_entry() {
    require_root
    echo
    title "指定端口（适配 NAT）"
    dim "只监听一个 VLESS Reality 端口，适合只有少量映射端口的 NAT 小鸡。"
    local port
    port="$(prompt_listen_port)" || return 1

    if [[ -f "$SB_STATE" ]]; then
        singbox_prepare
        load_sb_state
        ensure_singbox_binary "${SB_TAG:-latest}"
        apply_listen_port "$port" || return 1
        apply_singbox_config || { warn "应用失败。"; return 1; }
        ok "已更新监听端口：${PORT_VLESS}"
        print_links
        return 0
    fi

    local -a args=()
    if [[ -n "$port" ]]; then
        args+=(--port "$port")
    fi
    singbox_install "${args[@]}"
}

singbox_install() {
    while (($#)); do
        case "$1" in
            -H|--host) (($# >= 2)) || die "--host 缺少参数"; SB_HOST="$2"; shift 2 ;;
            --sni) (($# >= 2)) || die "--sni 缺少参数"; SB_SNI="$2"; shift 2 ;;
            --tls-sni) (($# >= 2)) || die "--tls-sni 缺少参数"; SB_SNI="$2"; shift 2 ;;
            --version) (($# >= 2)) || die "--version 缺少参数"; SB_TAG="$2"; shift 2 ;;
            --allow-private) SB_ALLOW_PRIVATE=1; shift ;;
            --no-warp|--single-warp)
                die "已移除 WARP 支持（$1 不再可用）。"
                ;;
            --single|--single-node)
                case "${2:-}" in
                    vless|reality|vless-reality) shift 2 ;;
                    anytls|anytls-tls) die "当前仅支持 VLESS Reality，已不再提供 AnyTLS 入站。" ;;
                    *) shift ;;
                esac
                ;;
            -p|--port)
                (($# >= 2)) || die "--port 缺少参数"
                is_valid_port "$2" || die "端口无效：$2"
                CLI_PORT=$((10#$2))
                shift 2
                ;;
            -f|--force) CLI_FORCE=1; shift ;;
            -h|--help) singbox_usage; return 0 ;;
            *) die "未知 install 参数：$1" ;;
        esac
    done

    if [[ -n "$SB_HOST" ]]; then
        is_valid_host "$SB_HOST" || die "入口地址无效：${SB_HOST}"
    fi
    is_valid_host "$SB_SNI" || die "SNI 无效：${SB_SNI}"

    singbox_prepare
    if [[ -f "$SB_STATE" && "$CLI_FORCE" -ne 1 ]]; then
        load_sb_state
        ensure_singbox_binary "$SB_TAG"
        if [[ -n "$CLI_PORT" ]]; then
            info "正在更新监听端口（保留现有凭证）..."
            apply_listen_port "$CLI_PORT" || die "端口更新失败。"
            apply_singbox_config || die "配置应用失败。"
            ok "监听端口：${PORT_VLESS}"
            print_links
            return 0
        fi
        if ((SB_DID_MIGRATE == 1)); then
            info "正在按新方案重建配置（保留 VLESS 凭证）..."
            ensure_system_user "$SB_USER"
            apply_singbox_config || die "迁移后启动失败。"
            ok "已迁移到单入站 VLESS Reality。"
            print_links
            return 0
        fi
        if [[ -t 0 || -e /dev/tty ]]; then
            if confirm "检测到已有安装，是否覆盖重装（重新分配端口与凭据）？" "n"; then
                CLI_FORCE=1
            fi
        fi
        if ((CLI_FORCE != 1)); then
            if ! service_is_active "$SB_SERVICE"; then
                info "检测到历史配置但服务未运行，正在重新应用并启动服务..."
                ensure_system_user "$SB_USER"
                apply_singbox_config || die "启动失败。"
                ok "sing-box 已恢复并启动。"
            else
                info "检测到已有安装，显示现有链接。覆盖请选重装或加 --force。"
            fi
            print_links
            return 0
        fi
    fi

    mkdir -p "$SB_DIR" "$SB_DATA_DIR"
    ensure_system_user "$SB_USER"
    ensure_route_file
    download_singbox "$SB_TAG"

    if [[ -n "$CLI_PORT" ]]; then
        if port_in_use "$CLI_PORT"; then
            die "端口 ${CLI_PORT} 已被占用，请换一个。"
        fi
        PORT_VLESS="$CLI_PORT"
    else
        PORT_VLESS="$(choose_random_port)" || die "无法分配空闲端口。"
    fi

    UUID="$(generate_uuid)"
    REALITY_SID="$(random_hex 8)"
    local kp
    kp="$("$SB_BIN" generate reality-keypair)" || die "无法生成 Reality 密钥对。"
    parse_reality_keypair "$kp" || die "无法解析 Reality 密钥对。"
    STATE_VERSION=4

    touch "$SB_LOG"
    chown "${SB_USER}:${SB_USER}" "$SB_LOG" 2>/dev/null || true
    apply_singbox_config || die "sing-box 启动失败。"
    service_is_active "$SB_SERVICE" || die "sing-box 未能保持运行。"
    ok "sing-box 已安装并开机自启。"
    print_links
}

singbox_update() {
    local version="latest"
    while (($#)); do
        case "$1" in
            --version) (($# >= 2)) || die "--version 缺少参数"; version="$2"; shift 2 ;;
            -h|--help) singbox_usage; return 0 ;;
            *) die "未知 update 参数：$1" ;;
        esac
    done
    singbox_prepare
    require_installed
    download_singbox "$version"
    apply_singbox_config || die "更新后启动失败。"
    ok "sing-box 已更新。"
    "$SB_BIN" version || true
}

singbox_status() {
    require_root
    if [[ -x "$SB_BIN" ]]; then
        "$SB_BIN" version 2>/dev/null || true
    fi
    if service_is_active "$SB_SERVICE"; then
        ok "服务运行中：${SB_SERVICE}"
    else
        warn "服务未运行：${SB_SERVICE}"
        if [[ -f "$SB_STATE" && ! -x "$SB_BIN" ]]; then
            dim "（二进制缺失，请在子菜单选择【1】或【2】完成安装与启动）"
        elif [[ -f "$SB_STATE" ]]; then
            dim "（请在子菜单选择【1】或【5】启动服务）"
        fi
    fi
    if [[ -f "$SB_STATE" ]]; then
        load_sb_state
        apply_if_legacy_layout
        echo "SNI:          ${SB_SNI}"
        echo "协议:         VLESS Reality"
        echo "端口:         ${PORT_VLESS}"
    fi
}

singbox_restart() {
    require_root
    require_openrc
    if [[ ! -f "$SB_STATE" ]]; then
        die "尚未安装，请先选择安装。"
    fi
    load_sb_state
    if ((SB_DID_MIGRATE == 1)); then
        apply_if_legacy_layout
        return 0
    fi
    if [[ ! -x "$SB_BIN" || ! -f "$SB_INIT" ]]; then
        info "检测到程序或服务未就绪，正在重新应用并启动服务..."
        apply_singbox_config || die "启动失败。"
        ok "sing-box 已启动。"
        return 0
    fi
    service_restart "$SB_SERVICE" || die "重启失败。"
    ok "已重启 ${SB_SERVICE}"
}

singbox_uninstall() {
    local purge=0
    while (($#)); do
        case "$1" in
            --purge) purge=1; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            -h|--help) singbox_usage; return 0 ;;
            *) die "未知 uninstall 参数：$1" ;;
        esac
    done
    require_root
    require_openrc
    confirm "确认卸载 Alpine sing-box？" "n" || { info "已取消卸载。"; return 0; }
    service_stop "$SB_SERVICE"
    service_disable "$SB_SERVICE"
    rm -f -- "$SB_INIT" "$SB_LOG"
    if [[ -L "$SB_BIN" ]]; then
        rm -f -- "$SB_BIN"
    elif [[ -f "$SB_BIN" && "$SB_BIN" == /usr/local/bin/sing-box ]]; then
        rm -f -- "$SB_BIN"
    fi
    if ((purge == 1)); then
        [[ "$SB_DIR" == /opt/alpine-sing-box ]] || die "拒绝删除非预期目录：${SB_DIR}"
        rm -rf -- "$SB_DIR"
        ok "已删除服务、二进制和配置。"
    else
        ok "已删除服务；配置保留在 ${SB_DIR}"
    fi
}

print_custom_routes() {
    ensure_route_file
    echo "本机出口: IPv4=$(default_ipv4_address || echo 无) IPv6=$(default_ipv6_address || echo 无)"
    echo
    jq -r '
      def match_text:
        [(.domain // [] | map("domain:" + .))[],
         (.domain_suffix // [] | map("suffix:" + .))[],
         (.domain_keyword // [] | map("keyword:" + .))[],
         (.domain_regex // [] | map("regex:" + .))[],
         (.rule_set // [] | map("rule-set:" + .))[]] | join(", ");
      "自定义路由规则:",
      (if ((.rules // []) | length) == 0 then "  （无）"
       else (.rules // [] | to_entries[] | "  \(.key + 1)) \((.value.name // "未命名")) -> \(.value.outbound) | \(.value | match_text)") end),
      "",
      "导入的远程出口:",
      (if ((.outbounds // []) | length) == 0 then "  （无）"
       else (.outbounds // [] | to_entries[] | "  \(.key + 1)) \(.value.tag) [\(.value.type)]") end)
    ' "$SB_ROUTE_JSON"
}

select_route_outbound() {
    local ip4 ip6 choice idx tag
    local -a imported=()
    SBP_SELECTED_OUTBOUND=""
    ip4="$(default_ipv4_address || true)"
    ip6="$(default_ipv6_address || true)"
    mapfile -t imported < <(jq -r '.outbounds[]?.tag' "$SB_ROUTE_JSON")
    echo "选择这条规则使用的出口："
    echo "  1) 本机 IPv4（direct-ipv4，当前 ${ip4:-未检测到}）"
    echo "  2) 本机 IPv6（direct-ipv6，当前 ${ip6:-未检测到}）"
    idx=3
    for tag in "${imported[@]:-}"; do
        [[ -n "$tag" ]] || continue
        echo "  ${idx}) 导入出口：${tag}"
        idx=$((idx + 1))
    done
    ask choice "选择出口: "
    case "$choice" in
        1) SBP_SELECTED_OUTBOUND="direct-ipv4" ;;
        2) SBP_SELECTED_OUTBOUND="direct-ipv6" ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                idx=$((choice - 3))
                if ((idx >= 0 && idx < ${#imported[@]})); then
                    SBP_SELECTED_OUTBOUND="${imported[$idx]}"
                fi
            fi
            ;;
    esac
    [[ -n "$SBP_SELECTED_OUTBOUND" ]] || { warn "无效出口选择"; return 1; }
}

add_custom_route_rule() {
    ensure_route_file
    select_route_outbound || return 1
    echo "匹配项，逗号或空格分隔。例：geosite:netflix suffix:openai.com"
    echo "简写：netflix → geosite；example.com → 域名后缀。"
    local matches name match_json tmp
    ask matches "匹配项: "
    match_json="$(parse_route_match_json "$matches")"
    if ! printf '%s' "$match_json" | jq -e '
        (((.domain // [])|length)+((.domain_suffix // [])|length)+((.domain_keyword // [])|length)+((.domain_regex // [])|length)+((.rule_set // [])|length)) > 0
    ' >/dev/null; then
        warn "没有可用匹配项。"
        return 1
    fi
    ask name "规则名称（可留空）: "
    tmp="$(mktemp)"
    jq -c --argjson match "$match_json" --arg outbound "$SBP_SELECTED_OUTBOUND" --arg name "$name" '
        .rules = (.rules // [])
        | .rule_set = (.rule_set // [])
        | .outbounds = (.outbounds // [])
        | .rules += [($match | del(.rule_set_defs) + {outbound:$outbound} + (if $name != "" then {name:$name} else {} end))]
        | .rule_set = ((.rule_set + ($match.rule_set_defs // [])) | unique_by(.tag))
    ' "$SB_ROUTE_JSON" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SB_ROUTE_JSON"
    apply_singbox_config || { warn "应用路由失败。"; return 1; }
    ok "路由规则已应用。"
}

import_custom_route_outbound() {
    ensure_route_file
    local tag raw outbound tmp
    ask tag "远程出口 tag（例如 hk-socks）: "
    valid_route_tag "$tag" || { warn "tag 只能包含字母数字和 ._-@!"; return 1; }
    case "$tag" in
        direct|direct-ipv4|direct-ipv6|warp) warn "该 tag 是保留名称。"; return 1 ;;
    esac
    echo "粘贴分享链接（优先 socks5h://user:pass@host:port），也支持 VLESS / AnyTLS / SOCKS / HTTP。"
    ask raw "节点配置: "
    [[ -f "$raw" ]] && raw="$(cat "$raw")"
    if printf '%s' "$raw" | jq -e 'type == "object" and (.type | type == "string")' >/dev/null 2>&1; then
        outbound="$(printf '%s' "$raw" | jq -c --arg tag "$tag" '.tag = $tag')"
    else
        outbound="$(share_link_to_outbound "$raw" "$tag" 2>/dev/null || true)"
    fi
    if [[ -z "${outbound:-}" ]] || ! printf '%s' "$outbound" | jq -e 'type == "object" and (.type|type=="string")' >/dev/null; then
        warn "无法识别。socks5h 示例：socks5h://user:pass@203.0.113.8:1080"
        return 1
    fi
    tmp="$(mktemp)"
    jq -c --argjson outbound "$outbound" '
        .outbounds = (((.outbounds // []) | map(select(.tag != $outbound.tag))) + [$outbound])
    ' "$SB_ROUTE_JSON" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SB_ROUTE_JSON"
    apply_singbox_config || { warn "导入出口后配置校验失败。"; return 1; }
    ok "已导入出口：${tag}"
}

remove_custom_route_rule() {
    ensure_route_file
    local idx tmp
    print_custom_routes
    ask idx "要删除的规则编号: "
    [[ "$idx" =~ ^[0-9]+$ ]] || { warn "编号无效"; return 1; }
    idx=$((idx - 1))
    tmp="$(mktemp)"
    jq -c --argjson idx "$idx" '
        .rules = ((.rules // []) | del(.[$idx]))
        | ([.rules[]?.rule_set[]?] | unique) as $used
        | .rule_set = ((.rule_set // []) | map(. as $rs | select($used | index($rs.tag))))
    ' "$SB_ROUTE_JSON" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SB_ROUTE_JSON"
    apply_singbox_config || return 1
    ok "已删除规则。"
}

remove_custom_route_outbound() {
    ensure_route_file
    local tag tmp
    print_custom_routes
    ask tag "要删除的远程出口 tag: "
    if jq -e --arg tag "$tag" 'any(.rules[]?; .outbound == $tag)' "$SB_ROUTE_JSON" >/dev/null; then
        warn "该出口仍被规则使用。"
        return 1
    fi
    tmp="$(mktemp)"
    jq -c --arg tag "$tag" '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' "$SB_ROUTE_JSON" >"$tmp" \
        || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SB_ROUTE_JSON"
    apply_singbox_config || return 1
    ok "已删除出口。"
}

custom_route_menu() {
    require_installed
    ensure_route_file
    while true; do
        echo
        title "自定义路由与分流"
        print_custom_routes
        echo
        echo "  1) 添加网址 / geosite 规则"
        echo "  2) 导入远程出口（socks5h / 分享链接）"
        echo "  3) 删除路由规则"
        echo "  4) 删除导入出口"
        echo "  0) 返回"
        local op
        ask op "请选择: "
        case "$op" in
            1) add_custom_route_rule; pause ;;
            2) import_custom_route_outbound; pause ;;
            3) remove_custom_route_rule; pause ;;
            4) remove_custom_route_outbound; pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

singbox_edit() {
    require_installed
    while true; do
        echo
        title "编辑节点信息"
        echo "  入口: ${SB_HOST:-自动探测}   SNI: ${SB_SNI}"
        echo "  VLESS Reality :${PORT_VLESS}"
        echo
        echo "  1) 修改入口地址（NAT / 域名）"
        echo "  2) 修改 SNI / Reality 握手域名"
        echo "  3) 修改监听端口"
        echo "  4) 重新生成 UUID / 密钥"
        echo "  0) 返回"
        local op val
        ask op "请选择: "
        case "$op" in
            1)
                ask val "入口地址: "
                is_valid_host "$val" || { warn "地址无效"; pause; continue; }
                SB_HOST="$val"
                apply_singbox_config && ok "已更新入口地址。" || warn "应用失败。"
                pause
                ;;
            2)
                ask val "SNI（当前 ${SB_SNI}）: "
                is_valid_host "$val" || { warn "SNI 无效"; pause; continue; }
                SB_SNI="$val"
                apply_singbox_config && ok "已更新 SNI。" || warn "应用失败。"
                pause
                ;;
            3)
                ask val "监听端口（当前 ${PORT_VLESS}）: "
                if [[ -z "$val" ]]; then
                    info "未更改。"
                    pause
                    continue
                fi
                if apply_listen_port "$val" && apply_singbox_config; then
                    ok "监听端口：${PORT_VLESS}"
                    print_links
                else
                    warn "应用失败。"
                fi
                pause
                ;;
            4)
                UUID="$(generate_uuid)"
                REALITY_SID="$(random_hex 8)"
                local kp
                kp="$("$SB_BIN" generate reality-keypair)" || { warn "生成密钥失败"; pause; continue; }
                parse_reality_keypair "$kp" || { warn "解析密钥失败"; pause; continue; }
                apply_singbox_config && ok "凭证已轮换。" || warn "应用失败。"
                print_links
                pause
                ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

singbox_menu() {
    while true; do
        echo
        printf '%sAlpine sing-box  v%s%s\n' "$C_BLUE" "$SB_VERSION_LABEL" "$C_RESET"
        dim "VLESS Reality · 自定义分流"
        echo "────────────────────────────────────────"
        echo "  1) 安装 / 覆盖重装（随机端口）"
        echo "  2) 指定端口（适配 NAT）"
        echo "  3) 查看分享链接"
        echo "  4) 运行状态"
        echo "  5) 启动 / 重启服务"
        echo "  6) 编辑节点信息"
        echo "  7) 自定义路由与分流"
        echo "  8) 更新核心"
        echo "  9) 卸载（保留配置）"
        echo "  0) 返回主菜单"
        echo "────────────────────────────────────────"
        local choice
        ask choice "请选择: "
        case "$choice" in
            1) singbox_install; pause ;;
            2) singbox_single_entry || true; pause ;;
            3) print_links; pause ;;
            4) singbox_status; pause ;;
            5) singbox_restart; pause ;;
            6) singbox_edit ;;
            7) custom_route_menu ;;
            8) singbox_update; pause ;;
            9) singbox_uninstall; pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

singbox_main() {
    local command="${1:-menu}"
    (($# == 0)) || shift
    case "$command" in
        menu) singbox_menu "$@" ;;
        install) singbox_install "$@" ;;
        single) singbox_single_entry ;;
        links|info) require_root; require_installed; print_links ;;
        status) singbox_status "$@" ;;
        restart) singbox_restart "$@" ;;
        edit) require_root; singbox_edit "$@" ;;
        routes|route) require_root; custom_route_menu "$@" ;;
        update|upgrade) singbox_update "$@" ;;
        uninstall) singbox_uninstall "$@" ;;
        help|-h|--help) singbox_usage ;;
        *) error "未知命令：$command"; singbox_usage; return 1 ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    singbox_main "$@"
fi
