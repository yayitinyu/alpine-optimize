#!/usr/bin/env bash
# Slim sing-box installer for Alpine / OpenRC.
# Trade-off: 4 useful inbounds instead of sing-box-plus's 20-node systemd stack.

if [[ -z "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

SB_VERSION_LABEL="1.0.0"
SB_GITHUB_REPO="SagerNet/sing-box"
SB_DIR="${SB_DIR:-/opt/alpine-sing-box}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_CONF="${SB_CONF:-${SB_DIR}/config.json}"
SB_STATE="${SB_STATE:-${SB_DIR}/state.env}"
SB_LINKS="${SB_LINKS:-${SB_DIR}/share-links.txt}"
SB_CERT_DIR="${SB_CERT_DIR:-${SB_DIR}/cert}"
SB_DATA_DIR="${SB_DATA_DIR:-${SB_DIR}/data}"
SB_SERVICE="${SB_SERVICE:-alpine-sing-box}"
SB_INIT="/etc/init.d/${SB_SERVICE}"
SB_LOG="${SB_LOG:-/var/log/alpine-sing-box.log}"
SB_USER="${SB_USER:-sing-box}"
MANAGED_MARKER="# Managed by alpine-optimize sing-box"

SB_HOST="${SB_HOST:-}"
SB_SNI="${SB_SNI:-www.microsoft.com}"
SB_TLS_SNI="${SB_TLS_SNI:-www.bing.com}"
SB_TAG="${SB_TAG:-latest}"
SB_ALLOW_PRIVATE="${SB_ALLOW_PRIVATE:-0}"
SB_LISTEN="${SB_LISTEN:-}"
CLI_FORCE=0

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
Alpine sing-box 精简节点（OpenRC）

这不是 sing-box-plus 的完整移植。20 节点、WARP、ACME 和 systemd
定时器对 Alpine 小鸡过重；这里提供 4 个常用入站：

  VLESS Reality · Hysteria2 · TUIC v5 · Shadowsocks 2022

用法：
  alpine.sh sing-box                  交互菜单
  alpine.sh sing-box install [选项]
  alpine.sh sing-box links
  alpine.sh sing-box status
  alpine.sh sing-box restart
  alpine.sh sing-box update [--version TAG]
  alpine.sh sing-box uninstall [--purge] [--yes]

install 选项：
  -H, --host HOST          客户端连接地址（IPv4 或域名）
      --sni HOST           Reality 握手 / SNI，默认 www.microsoft.com
      --tls-sni HOST       自签证书 CN，默认 www.bing.com
      --version TAG        指定 sing-box 版本，例如 v1.12.10
      --allow-private      允许代理访问内网地址
  -f, --force              覆盖已有安装
EOF
}

singbox_prepare() {
    require_root
    require_alpine
    require_openrc
    enable_community_repo
    ensure_packages curl ca-certificates tar jq openssl coreutils iproute2 shadow libcap
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

b64_nopad() {
    openssl base64 -A | tr -d '='
}

generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
    else
        printf '%s-%s-%s-%s-%s\n' "$(random_hex 8)" "$(random_hex 4)" "$(random_hex 4)" "$(random_hex 4)" "$(random_hex 12)"
    fi
}

choose_unique_ports() {
    local count="$1"
    local -a used=()
    local port i j dup
    for ((i = 0; i < count; i++)); do
        dup=1
        for ((j = 0; j < 64 && dup == 1; j++)); do
            port="$(choose_random_port)" || die "无法分配空闲端口。"
            dup=0
            local existing
            for existing in "${used[@]:-}"; do
                [[ "$existing" == "$port" ]] && dup=1
            done
        done
        ((dup == 0)) || die "无法分配不重复端口。"
        used+=("$port")
    done
    printf '%s\n' "${used[*]}"
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
    local goarch tmp json url tag archive extracted label
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

    url=""
    label=""
    local pattern
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

ensure_self_signed_cert() {
    mkdir -p "$SB_CERT_DIR"
    local key="${SB_CERT_DIR}/key.pem"
    local crt="${SB_CERT_DIR}/cert.pem"
    if [[ -f "$key" && -f "$crt" ]]; then
        return 0
    fi
    openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$key" -out "$crt" \
        -subj "/CN=${SB_TLS_SNI}" >/dev/null 2>&1 \
        || die "生成自签证书失败。"
    chmod 600 "$key"
    chmod 644 "$crt"
}

render_singbox_config() {
    local private_rule=""
    local listen
    listen="$(default_listen_address)"
    if ((SB_ALLOW_PRIVATE == 0)); then
        private_rule=',
      {
        "ip_is_private": true,
        "action": "reject"
      }'
    fi

    cat <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true,
    "output": "${SB_LOG}"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "${listen}",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SB_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SB_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${REALITY_SID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "${listen}",
      "listen_port": ${PORT_HY2},
      "users": [
        {
          "password": "${HY2_PWD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SB_TLS_SNI}",
        "certificate_path": "${SB_CERT_DIR}/cert.pem",
        "key_path": "${SB_CERT_DIR}/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "${listen}",
      "listen_port": ${PORT_TUIC},
      "users": [
        {
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PWD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${SB_TLS_SNI}",
        "alpn": ["h3"],
        "certificate_path": "${SB_CERT_DIR}/cert.pem",
        "key_path": "${SB_CERT_DIR}/key.pem"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss2022",
      "listen": "${listen}",
      "listen_port": ${PORT_SS},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_KEY}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }${private_rule}
    ],
    "final": "direct"
  }
}
EOF
}

# Testable share-link builders.
vless_share_link() {
    local host="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" name="${7:-vless-reality}"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$uuid" "$host" "$port" "$(urlencode "$sni")" "$pbk" "$sid" "$(urlencode "$name")"
}

hy2_share_link() {
    local host="$1" port="$2" password="$3" sni="$4" name="${5:-hysteria2}"
    printf 'hysteria2://%s@%s:%s?insecure=1&sni=%s#%s\n' \
        "$(urlencode "$password")" "$host" "$port" "$(urlencode "$sni")" "$(urlencode "$name")"
}

tuic_share_link() {
    local host="$1" port="$2" uuid="$3" password="$4" sni="$5" name="${6:-tuic}"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1&sni=%s#%s\n' \
        "$uuid" "$(urlencode "$password")" "$host" "$port" "$(urlencode "$sni")" "$(urlencode "$name")"
}

ss2022_share_link() {
    local host="$1" port="$2" key="$3" name="${4:-ss2022}"
    local userinfo
    userinfo="$(printf '%s' "2022-blake3-aes-128-gcm:${key}" | b64_nopad)"
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$(urlencode "$name")"
}

write_share_links() {
    local host="${SB_HOST}"
    [[ -n "$host" ]] || host="$(discover_public_ipv4)"
    {
        vless_share_link "$host" "$PORT_VLESS" "$UUID" "$SB_SNI" "$REALITY_PUB" "$REALITY_SID"
        hy2_share_link "$host" "$PORT_HY2" "$HY2_PWD" "$SB_TLS_SNI"
        tuic_share_link "$host" "$PORT_TUIC" "$TUIC_UUID" "$TUIC_PWD" "$SB_TLS_SNI"
        ss2022_share_link "$host" "$PORT_SS" "$SS_KEY"
    } >"$SB_LINKS"
    chmod 600 "$SB_LINKS"
}

write_sb_state() {
    write_file "$SB_STATE" 0600 <<EOF
STATE_VERSION=1
SB_HOST=$(printf '%q' "$SB_HOST")
SB_SNI=$(printf '%q' "$SB_SNI")
SB_TLS_SNI=$(printf '%q' "$SB_TLS_SNI")
UUID=$(printf '%q' "$UUID")
REALITY_PRIV=$(printf '%q' "$REALITY_PRIV")
REALITY_PUB=$(printf '%q' "$REALITY_PUB")
REALITY_SID=$(printf '%q' "$REALITY_SID")
HY2_PWD=$(printf '%q' "$HY2_PWD")
TUIC_UUID=$(printf '%q' "$TUIC_UUID")
TUIC_PWD=$(printf '%q' "$TUIC_PWD")
SS_KEY=$(printf '%q' "$SS_KEY")
PORT_VLESS=$(printf '%q' "$PORT_VLESS")
PORT_HY2=$(printf '%q' "$PORT_HY2")
PORT_TUIC=$(printf '%q' "$PORT_TUIC")
PORT_SS=$(printf '%q' "$PORT_SS")
SB_ALLOW_PRIVATE=$(printf '%q' "$SB_ALLOW_PRIVATE")
INSTALLED_AT=$(printf '%q' "$(iso_now)")
EOF
}

load_sb_state() {
    [[ -f "$SB_STATE" ]] || die "没有找到安装状态：${SB_STATE}"
    # shellcheck disable=SC1090
    source "$SB_STATE"
}

write_sb_init() {
    write_file "$SB_INIT" 0755 <<EOF
#!/sbin/openrc-run
${MANAGED_MARKER}

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

print_links() {
    [[ -f "$SB_LINKS" ]] || die "尚未安装，或分享链接不存在。"
    echo
    printf '%ssing-box 分享链接%s\n' "$C_BOLD" "$C_RESET"
    cat "$SB_LINKS"
    echo
    info "完整副本：${SB_LINKS}"
    warn "Hysteria2 / TUIC 使用自签证书，客户端需允许 insecure。"
    warn "云安全组需放行以上 4 个端口（VLESS=TCP，其余含 UDP）。"
}

singbox_install() {
    local ports
    while (($#)); do
        case "$1" in
            -H|--host) (($# >= 2)) || die "--host 缺少参数"; SB_HOST="$2"; shift 2 ;;
            --sni) (($# >= 2)) || die "--sni 缺少参数"; SB_SNI="$2"; shift 2 ;;
            --tls-sni) (($# >= 2)) || die "--tls-sni 缺少参数"; SB_TLS_SNI="$2"; shift 2 ;;
            --version) (($# >= 2)) || die "--version 缺少参数"; SB_TAG="$2"; shift 2 ;;
            --allow-private) SB_ALLOW_PRIVATE=1; shift ;;
            -f|--force) CLI_FORCE=1; shift ;;
            -h|--help) singbox_usage; return 0 ;;
            *) die "未知 install 参数：$1" ;;
        esac
    done

    if [[ -n "$SB_HOST" ]]; then
        is_valid_host "$SB_HOST" || die "入口地址无效：${SB_HOST}"
    fi
    is_valid_host "$SB_SNI" || die "SNI 无效：${SB_SNI}"
    is_valid_host "$SB_TLS_SNI" || die "TLS SNI 无效：${SB_TLS_SNI}"

    singbox_prepare
    if [[ -f "$SB_STATE" && "$CLI_FORCE" -ne 1 ]]; then
        info "检测到已有安装，显示现有链接。覆盖请加 --force。"
        load_sb_state
        print_links
        return 0
    fi

    mkdir -p "$SB_DIR" "$SB_DATA_DIR" "$SB_CERT_DIR"
    ensure_system_user "$SB_USER"
    download_singbox "$SB_TAG"
    ensure_self_signed_cert

    ports="$(choose_unique_ports 4)"
    # shellcheck disable=SC2206
    local -a port_arr=($ports)
    PORT_VLESS="${port_arr[0]}"
    PORT_HY2="${port_arr[1]}"
    PORT_TUIC="${port_arr[2]}"
    PORT_SS="${port_arr[3]}"

    UUID="$(generate_uuid)"
    TUIC_UUID="$(generate_uuid)"
    HY2_PWD="$(random_hex 16)"
    TUIC_PWD="$(random_hex 16)"
    SS_KEY="$("$SB_BIN" generate rand --base64 16 2>/dev/null || openssl rand -base64 16)"
    REALITY_SID="$(random_hex 8)"
    local kp
    kp="$("$SB_BIN" generate reality-keypair)" || die "无法生成 Reality 密钥对。"
    parse_reality_keypair "$kp" || die "无法解析 Reality 密钥对。"

    local tmp_conf
    tmp_conf="$(mktemp "${SB_DIR}/config.json.tmp.XXXXXX")"
    register_temp "$tmp_conf"
    render_singbox_config >"$tmp_conf"
    "$SB_BIN" check -c "$tmp_conf" || die "生成的 sing-box 配置校验失败。"
    install -m 0640 "$tmp_conf" "$SB_CONF"
    chown "${SB_USER}:${SB_USER}" "$SB_CONF" "$SB_DIR" "$SB_DATA_DIR" "$SB_CERT_DIR" \
        "${SB_CERT_DIR}/key.pem" "${SB_CERT_DIR}/cert.pem" 2>/dev/null || true

    write_sb_state
    write_share_links
    write_sb_init
    touch "$SB_LOG"
    chown "${SB_USER}:${SB_USER}" "$SB_LOG" 2>/dev/null || true
    service_enable "$SB_SERVICE"
    service_restart "$SB_SERVICE" || {
        tail -n 40 "$SB_LOG" >&2 || true
        die "sing-box 启动失败。"
    }
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
    [[ -f "$SB_STATE" ]] || die "尚未安装。"
    download_singbox "$version"
    "$SB_BIN" check -c "$SB_CONF" || die "现有配置与新版本不兼容。"
    service_restart "$SB_SERVICE" || die "更新后启动失败。"
    ok "sing-box 已更新。"
    "$SB_BIN" version || true
}

singbox_status() {
    require_root
    if [[ -x "$SB_BIN" ]]; then
        "$SB_BIN" version || true
    fi
    if service_is_active "$SB_SERVICE"; then
        ok "服务运行中：${SB_SERVICE}"
    else
        warn "服务未运行：${SB_SERVICE}"
    fi
    if [[ -f "$SB_STATE" ]]; then
        load_sb_state
        echo "VLESS:  ${PORT_VLESS}"
        echo "HY2:    ${PORT_HY2}"
        echo "TUIC:   ${PORT_TUIC}"
        echo "SS2022: ${PORT_SS}"
    fi
}

singbox_restart() {
    require_root
    require_openrc
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
    confirm "确认卸载 Alpine sing-box？" "n" || die "已取消卸载。"
    service_stop "$SB_SERVICE"
    service_disable "$SB_SERVICE"
    rm -f -- "$SB_INIT" "$SB_BIN" "$SB_LOG"
    if ((purge == 1)); then
        [[ "$SB_DIR" == /opt/alpine-sing-box ]] || die "拒绝删除非预期目录：${SB_DIR}"
        rm -rf -- "$SB_DIR"
        ok "已删除服务、二进制和配置。"
    else
        ok "已删除服务和二进制；配置保留在 ${SB_DIR}"
    fi
}

singbox_menu() {
    local choice
    printf '%sAlpine sing-box 精简节点 v%s%s\n' "$C_BLUE" "$SB_VERSION_LABEL" "$C_RESET"
    cat <<'EOF'
  1) 安装 / 显示链接
  2) 查看分享链接
  3) 状态
  4) 重启
  5) 更新核心
  6) 卸载（保留配置）
  0) 返回
EOF
    prompt_value choice "请选择" "1"
    case "$choice" in
        1) singbox_install ;;
        2) print_links ;;
        3) singbox_status ;;
        4) singbox_restart ;;
        5) singbox_update ;;
        6) singbox_uninstall ;;
        0) return 0 ;;
        *) die "无效选择：$choice" ;;
    esac
}

singbox_main() {
    local command="${1:-menu}"
    (($# == 0)) || shift
    case "$command" in
        menu) singbox_menu "$@" ;;
        install) singbox_install "$@" ;;
        links|info) require_root; load_sb_state; print_links ;;
        status) singbox_status "$@" ;;
        restart) singbox_restart "$@" ;;
        update|upgrade) singbox_update "$@" ;;
        uninstall) singbox_uninstall "$@" ;;
        help|-h|--help) singbox_usage ;;
        *) error "未知命令：$command"; singbox_usage; return 1 ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    singbox_main "$@"
fi
