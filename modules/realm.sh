#!/usr/bin/env bash
# Realm port-forward manager for Alpine / OpenRC.
# Logic adapted from realm/realm.sh; systemd replaced with OpenRC.

if [[ -z "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

REALM_SCRIPT_VERSION="1.1.0"
GITHUB_REPO="zhboner/realm"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"

REALM_BIN="${REALM_BIN:-/usr/local/bin/realm}"
REALM_DIR="${REALM_DIR:-/etc/realm}"
REALM_CONFIG="${REALM_CONFIG:-${REALM_DIR}/config.toml}"
REALM_STATE="${REALM_STATE:-${REALM_DIR}/routes.tsv}"
REALM_PROTOCOL_FILE="${REALM_PROTOCOL_FILE:-${REALM_DIR}/protocol}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-/etc/init.d/realm}"
REALM_SERVICE_NAME="${REALM_SERVICE_NAME:-realm}"
REALM_USER="${REALM_USER:-realm}"
REALM_LOG="${REALM_LOG:-/var/log/realm.log}"
REALM_MANAGED_MARKER="# Managed by alpine-optimize realm"

LAST_TEMP_DIR=""
TEMP_DIRS=()

realm_temp_dir() {
    LAST_TEMP_DIR="$(new_temp_dir)"
    TEMP_DIRS+=("$LAST_TEMP_DIR")
}

realm_usage() {
    cat <<'EOF'
Realm 端口转发管理（Alpine / OpenRC）

用法：
  alpine.sh realm                         打开交互式菜单
  alpine.sh realm install [选项]          安装/更新 Realm 并配置 OpenRC
  alpine.sh realm add [选项]              添加一条转发规则
  alpine.sh realm edit <ID> [选项]        编辑一条转发规则
  alpine.sh realm delete <ID>             删除一条转发规则（剩余规则重新编号）
  alpine.sh realm protocol <tcp|udp|both> 设置全部规则使用的协议
  alpine.sh realm list                    列出规则
  alpine.sh realm status                  查看版本、规则和服务状态
  alpine.sh realm logs [-f]               查看最近日志（-f 持续跟踪）
  alpine.sh realm update [--version TAG]  更新 Realm（默认最新版）
  alpine.sh realm uninstall [--purge]     卸载服务；默认保留配置

install / add / edit 选项：
  --listen <PORT|IP:PORT>          本机监听端口或地址
  --remote <HOST:PORT>             目标地址（IPv6 请写成 [::1]:443）
  --protocol <tcp|udp|both>        全局协议，默认 both（仅 install）
  --version <TAG>                  安装指定版本，例如 v2.9.4
  --force                          备份并接管非本脚本管理的旧配置/服务

添加或删除规则后，ID 会按当前顺序重新编号为 1..N。

环境变量：
  REALM_TARGET                     覆盖自动检测的发布目标，例如
                                   x86_64-unknown-linux-musl
EOF
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || { error "无效端口：$port"; return 1; }
    ((10#$port >= 1 && 10#$port <= 65535)) || { error "端口必须在 1-65535：$port"; return 1; }
}

validate_ipv4() {
    local address="$1"
    local part
    local parts=()
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a parts <<<"$address"
    for part in "${parts[@]}"; do
        ((10#$part <= 255)) || return 1
    done
}

validate_listen_endpoint() {
    local endpoint="$1"
    local host=""
    local port=""

    if [[ "$endpoint" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" == *:* ]] || { error "IPv6 监听地址格式无效：$endpoint"; return 1; }
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        validate_ipv4 "$host" || { error "监听地址必须是 IPv4、方括号包裹的 IPv6，或仅端口：$endpoint"; return 1; }
    else
        error "监听地址格式无效：$endpoint"
        return 1
    fi
    validate_port "$port"
}

normalize_listen() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]{1,5}$ ]]; then
        validate_port "$input" || return 1
        printf '0.0.0.0:%s\n' "$input"
    else
        validate_listen_endpoint "$input" || return 1
        printf '%s\n' "$input"
    fi
}

validate_remote_endpoint() {
    local endpoint="$1"
    local host=""
    local port=""

    if [[ "$endpoint" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" == *:* ]] || { error "IPv6 目标地址格式无效：$endpoint"; return 1; }
    elif [[ "$endpoint" =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        if [[ "$host" =~ ^[0-9.]+$ ]]; then
            validate_ipv4 "$host" || { error "IPv4 目标地址无效：$endpoint"; return 1; }
        fi
    else
        error "目标地址格式无效：$endpoint（域名仅支持 ASCII；国际域名请使用 Punycode）"
        return 1
    fi
    validate_port "$port"
}

validate_protocol() {
    case "$1" in
        tcp|udp|both) return 0 ;;
        *) error "协议必须是 tcp、udp 或 both：$1"; return 1 ;;
    esac
}

route_count() {
    local state_file="$1"
    awk -F '\t' '!/^#/ && NF >= 3 { count++ } END { print count + 0 }' "$state_file"
}

next_route_id() {
    local state_file="$1"
    awk -F '\t' '!/^#/ && $1 ~ /^[0-9]+$/ && $1 > max { max = $1 } END { print max + 1 }' "$state_file"
}

# Rewrite IDs as 1..N in file order so add/delete never leave gaps.
compact_routes() {
    local state_file="$1"
    local tmp
    tmp="${state_file}.compact.$$"
    {
        printf '# id\tlisten\tremote\n'
        awk -F '\t' 'BEGIN { OFS = FS }
            !/^#/ && NF >= 3 { n++; print n, $2, $3 }
        ' "$state_file"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" >"$state_file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

read_route() {
    local state_file="$1"
    local id="$2"
    local line=""
    ROUTE_LISTEN=""
    ROUTE_REMOTE=""
    line="$(awk -F '\t' -v id="$id" '
        !/^#/ && $1 == id { print $2 "\t" $3; found = 1; exit }
        END { exit !found }
    ' "$state_file")" || return 1
    ROUTE_LISTEN="${line%%$'\t'*}"
    ROUTE_REMOTE="${line#*$'\t'}"
}

validate_state_file() {
    local state_file="$1"
    local id listen remote extra
    [[ -f "$state_file" ]] || { error "规则状态文件不存在：$state_file"; return 1; }

    while IFS=$'\t' read -r id listen remote extra || [[ -n "${id:-}" ]]; do
        [[ -z "${id:-}" || "$id" == \#* ]] && continue
        [[ "$id" =~ ^[0-9]+$ && -z "${extra:-}" ]] || { error "规则状态文件格式错误（ID=$id）。"; return 1; }
        validate_listen_endpoint "$listen" || return 1
        validate_remote_endpoint "$remote" || return 1
    done <"$state_file"
}

append_route_to_state() {
    local state_file="$1"
    local listen_input="$2"
    local remote="$3"
    local listen=""
    local id

    listen="$(normalize_listen "$listen_input")" || return 1
    validate_remote_endpoint "$remote" || return 1

    if awk -F '\t' -v listen="$listen" -v remote="$remote" \
        '!/^#/ && $2 == listen && $3 == remote { found = 1 } END { exit !found }' "$state_file"; then
        error "相同规则已存在：$listen -> $remote"
        return 1
    fi

    id="$(next_route_id "$state_file")"
    printf '%s\t%s\t%s\n' "$id" "$listen" "$remote" >>"$state_file"
    compact_routes "$state_file" || return 1
    route_count "$state_file"
}

delete_route_from_state() {
    local state_file="$1"
    local id="$2"
    local tmp
    local awk_status=0

    tmp="${state_file}.del.$$"
    awk -F '\t' -v id="$id" 'BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        $1 == id { found = 1; next }
        { print }
        END { if (!found) exit 2 }
    ' "$state_file" >"$tmp" || awk_status=$?
    if [[ "$awk_status" -ne 0 ]]; then
        rm -f -- "$tmp"
        return 1
    fi
    cat "$tmp" >"$state_file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    compact_routes "$state_file"
}

update_route_in_state() {
    local state_file="$1"
    local id="$2"
    local listen_input="$3"
    local remote_input="$4"
    local listen="" remote="" tmp

    read_route "$state_file" "$id" || { error "未找到规则 ID：$id"; return 1; }

    if [[ -n "$listen_input" ]]; then
        listen="$(normalize_listen "$listen_input")" || return 1
    else
        listen="$ROUTE_LISTEN"
    fi
    if [[ -n "$remote_input" ]]; then
        validate_remote_endpoint "$remote_input" || return 1
        remote="$remote_input"
    else
        remote="$ROUTE_REMOTE"
    fi

    if awk -F '\t' -v id="$id" -v listen="$listen" -v remote="$remote" \
        '!/^#/ && $1 != id && $2 == listen && $3 == remote { found = 1 } END { exit !found }' "$state_file"; then
        error "相同规则已存在：$listen -> $remote"
        return 1
    fi

    tmp="${state_file}.edit.$$"
    awk -F '\t' -v id="$id" -v listen="$listen" -v remote="$remote" 'BEGIN { OFS = FS }
        /^#/ || NF == 0 { print; next }
        $1 == id { print id, listen, remote; found = 1; next }
        { print }
        END { if (!found) exit 2 }
    ' "$state_file" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" >"$state_file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    printf '%s\n' "$id"
}

render_config() {
    local state_file="$1"
    local protocol="$2"
    local output_file="$3"
    local no_tcp="false"
    local use_udp="true"
    local id listen remote extra

    validate_protocol "$protocol" || return 1
    validate_state_file "$state_file" || return 1
    case "$protocol" in
        tcp) no_tcp="false"; use_udp="false" ;;
        udp) no_tcp="true"; use_udp="true" ;;
        both) no_tcp="false"; use_udp="true" ;;
    esac

    {
        printf '%s\n' "$REALM_MANAGED_MARKER"
        printf '%s\n\n' "# Use alpine.sh realm to add, edit or delete routes; manual changes may be overwritten."
        printf '[log]\nlevel = "warn"\noutput = "stdout"\n\n'
        printf '[network]\nno_tcp = %s\nuse_udp = %s\n\n' "$no_tcp" "$use_udp"
        while IFS=$'\t' read -r id listen remote extra || [[ -n "${id:-}" ]]; do
            [[ -z "${id:-}" || "$id" == \#* ]] && continue
            printf '# Route ID: %s\n' "$id"
            printf '[[endpoints]]\nlisten = "%s"\nremote = "%s"\n\n' "$listen" "$remote"
        done <"$state_file"
    } >"$output_file"
}

read_protocol() {
    local protocol="both"
    if [[ -f "$REALM_PROTOCOL_FILE" ]]; then
        IFS= read -r protocol <"$REALM_PROTOCOL_FILE" || true
    fi
    validate_protocol "$protocol" >/dev/null 2>&1 || protocol="both"
    printf '%s\n' "$protocol"
}

is_managed_file() {
    local path="$1"
    # Accept the realm marker, plus the sing-box marker that an earlier
    # alpine.sh global-variable clash accidentally wrote into Realm files.
    [[ -f "$path" ]] && grep -Eqx '# Managed by alpine-optimize (realm|sing-box)' "$path"
}

is_installed() {
    [[ -x "$REALM_BIN" && -f "$REALM_CONFIG" && -f "$REALM_STATE" && -f "$REALM_SERVICE_FILE" ]]
}

show_recent_logs() {
    if [[ -f "$REALM_LOG" ]]; then
        tail -n 30 "$REALM_LOG" || true
    else
        warn "尚未生成日志文件：${REALM_LOG}"
    fi
}

restart_and_verify() {
    service_restart "$REALM_SERVICE_NAME" || return 1
    service_is_active "$REALM_SERVICE_NAME"
}

apply_configuration() {
    local candidate_state="$1"
    local candidate_protocol="$2"
    local tmp_dir old_state old_protocol old_config new_config protocol_source

    validate_protocol "$candidate_protocol" || return 1
    validate_state_file "$candidate_state" || return 1
    (($(route_count "$candidate_state") > 0)) || { error "至少需要一条转发规则。"; return 1; }

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    old_state="$tmp_dir/old-routes.tsv"
    old_protocol="$tmp_dir/old-protocol"
    old_config="$tmp_dir/old-config.toml"
    new_config="$tmp_dir/new-config.toml"
    protocol_source="$tmp_dir/new-protocol"

    cp -p "$REALM_STATE" "$old_state"
    cp -p "$REALM_PROTOCOL_FILE" "$old_protocol"
    cp -p "$REALM_CONFIG" "$old_config"
    render_config "$candidate_state" "$candidate_protocol" "$new_config"
    printf '%s\n' "$candidate_protocol" >"$protocol_source"

    install -m 0600 "$candidate_state" "$REALM_STATE"
    install -m 0644 "$protocol_source" "$REALM_PROTOCOL_FILE"
    install -m 0644 "$new_config" "$REALM_CONFIG"

    if restart_and_verify; then
        return 0
    fi

    error "Realm 重启失败，正在恢复原配置。"
    install -m 0600 "$old_state" "$REALM_STATE"
    install -m 0644 "$old_protocol" "$REALM_PROTOCOL_FILE"
    install -m 0644 "$old_config" "$REALM_CONFIG"
    service_restart "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    show_recent_logs
    return 1
}

detect_target() {
    local arch libc="gnu"
    if [[ -n "${REALM_TARGET:-}" ]]; then
        [[ "$REALM_TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "REALM_TARGET 含有无效字符。"
        printf '%s\n' "$REALM_TARGET"
        return 0
    fi

    arch="$(uname -m)"
    if { ldd --version 2>&1 || true; } | grep -qi musl \
        || compgen -G '/lib/ld-musl-*.so*' >/dev/null \
        || is_alpine; then
        libc="musl"
    fi

    case "$arch" in
        x86_64|amd64) printf 'x86_64-unknown-linux-%s\n' "$libc" ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-%s\n' "$libc" ;;
        armv7l|armv7) printf 'armv7-unknown-linux-%seabihf\n' "$libc" ;;
        armv6l|arm) printf 'arm-unknown-linux-%seabihf\n' "$libc" ;;
        mips) printf 'mips-unknown-linux-%s\n' "$libc" ;;
        mipsel) printf 'mipsel-unknown-linux-%s\n' "$libc" ;;
        mips64) [[ "$libc" == "gnu" ]] && printf 'mips64-unknown-linux-gnuabi64\n' || printf 'mips64-unknown-linux-muslabi64\n' ;;
        mips64el) [[ "$libc" == "gnu" ]] && printf 'mips64el-unknown-linux-gnuabi64\n' || printf 'mips64el-unknown-linux-muslabi64\n' ;;
        *) die "不支持的 CPU 架构：$arch。可通过 REALM_TARGET 手动指定官方发布目标。" ;;
    esac
}

parse_release_tag() {
    local release_json="$1"
    jq -r '.tag_name // empty' "$release_json" | head -n 1
}

parse_asset_digest() {
    local release_json="$1"
    local asset="$2"
    jq -r --arg asset "$asset" \
        '.assets[]? | select(.name == $asset) | (.digest // empty)' \
        "$release_json" |
        sed -n 's/^sha256:\([0-9a-fA-F]\{64\}\)$/\1/p' |
        head -n 1
}

realm_install_dependencies() {
    local missing=()
    local command_name
    for command_name in curl tar awk sed grep jq install mktemp uname find head; do
        command_exists "$command_name" || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) && return 0

    warn "缺少依赖：$(join_by ', ' "${missing[@]}")，正在安装。"
    enable_community_repo
    apk_add curl ca-certificates tar coreutils findutils gawk sed grep jq libcap shadow
    for command_name in curl tar awk sed grep jq install mktemp uname find head; do
        command_exists "$command_name" || die "依赖安装后仍未找到：$command_name。"
    done
}

download_realm_binary() {
    local destination="$1"
    local requested_version="${2:-latest}"
    local target asset api_url tmp_dir release_json archive
    local tag digest actual_digest download_url extracted

    target="$(detect_target)"
    asset="realm-${target}.tar.gz"
    if [[ "$requested_version" == "latest" ]]; then
        api_url="${GITHUB_API}/releases/latest"
    else
        [[ "$requested_version" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || die "版本号格式无效：$requested_version"
        [[ "$requested_version" == v* ]] || requested_version="v${requested_version}"
        api_url="${GITHUB_API}/releases/tags/${requested_version}"
    fi

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    release_json="$tmp_dir/release.json"
    archive="$tmp_dir/$asset"

    info "查询 Realm ${requested_version}（${target}）..."
    curl -fsSL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: alpine-optimize-realm' \
        -o "$release_json" "$api_url" || die "无法获取 Realm 发布信息。"

    tag="$(parse_release_tag "$release_json")"
    [[ -n "$tag" ]] || die "发布信息中缺少版本号。"
    digest="$(parse_asset_digest "$release_json" "$asset")"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || \
        die "版本 $tag 没有适用于 ${target} 且带有效 SHA-256 摘要的完整功能发布包。"

    download_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
    info "下载 Realm ${tag}..."
    curl -fsSL --retry 3 --connect-timeout 15 -o "$archive" "$download_url" || die "Realm 下载失败。"
    actual_digest="$(sha256_file "$archive")"
    [[ "${actual_digest,,}" == "${digest,,}" ]] || die "Realm 下载文件 SHA-256 校验失败。"

    tar -xzf "$archive" -C "$tmp_dir"
    extracted="$(find "$tmp_dir" -type f -name realm -print -quit)"
    [[ -n "$extracted" ]] || die "发布包中未找到 realm 可执行文件。"
    install -m 0755 "$extracted" "$destination"
    "$destination" --version >/dev/null 2>&1 || die "下载的 Realm 可执行文件无法在当前系统运行。"
    info "已校验 Realm ${tag}。"
}

replace_binary() {
    local version="${1:-latest}"
    local restart_service="${2:-yes}"
    local tmp_dir candidate backup had_old="no"

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate="$tmp_dir/realm.new"
    backup="$tmp_dir/realm.old"
    download_realm_binary "$candidate" "$version"

    install -d -m 0755 "$(dirname "$REALM_BIN")"
    if [[ -e "$REALM_BIN" ]]; then
        cp -p "$REALM_BIN" "$backup"
        had_old="yes"
    fi
    install -m 0755 "$candidate" "${REALM_BIN}.new"
    mv -f "${REALM_BIN}.new" "$REALM_BIN"
    if command_exists setcap; then
        setcap cap_net_bind_service=+ep "$REALM_BIN" 2>/dev/null || true
    fi

    if [[ "$restart_service" == "yes" && -f "$REALM_SERVICE_FILE" ]]; then
        if restart_and_verify; then
            return 0
        fi
        error "新版本启动失败，正在恢复旧版本。"
        if [[ "$had_old" == "yes" ]]; then
            install -m 0755 "$backup" "$REALM_BIN"
            service_restart "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
        fi
        show_recent_logs
        return 1
    fi
}

write_service_file() {
    local output_file="$1"
    {
        cat <<EOF
#!/sbin/openrc-run
${REALM_MANAGED_MARKER}

name="${REALM_SERVICE_NAME}"
description="Realm network relay"
command="${REALM_BIN}"
command_args="-c ${REALM_CONFIG}"
command_background="yes"
pidfile="/run/${REALM_SERVICE_NAME}.pid"
command_user="${REALM_USER}:${REALM_USER}"
output_log="${REALM_LOG}"
error_log="${REALM_LOG}"
capabilities="^cap_net_bind_service"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -m 0640 -o ${REALM_USER}:${REALM_USER} "${REALM_LOG}"
}
EOF
    } >"$output_file"
}

install_service() {
    local tmp_dir candidate old_service had_old="no"
    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate="$tmp_dir/realm.init"
    old_service="$tmp_dir/realm.init.old"
    write_service_file "$candidate"

    ensure_system_user "$REALM_USER"
    install -d -m 0755 "$(dirname "$REALM_SERVICE_FILE")"
    if [[ -f "$REALM_SERVICE_FILE" ]]; then
        cp -p "$REALM_SERVICE_FILE" "$old_service"
        had_old="yes"
    fi
    install -m 0755 "$candidate" "$REALM_SERVICE_FILE"
    touch "$REALM_LOG"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_LOG" 2>/dev/null || true
    service_enable "$REALM_SERVICE_NAME"

    if restart_and_verify; then
        return 0
    fi

    error "Realm 服务启动失败。"
    if [[ "$had_old" == "yes" ]]; then
        install -m 0755 "$old_service" "$REALM_SERVICE_FILE"
        service_restart "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
    else
        service_disable "$REALM_SERVICE_NAME"
        rm -f -- "$REALM_SERVICE_FILE"
    fi
    show_recent_logs
    return 1
}

create_backup() {
    local backup_dir="${REALM_DIR}/backups/$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 0700 "$backup_dir"
    [[ -f "$REALM_CONFIG" ]] && cp -p "$REALM_CONFIG" "$backup_dir/config.toml"
    [[ -f "$REALM_STATE" ]] && cp -p "$REALM_STATE" "$backup_dir/routes.tsv"
    [[ -f "$REALM_PROTOCOL_FILE" ]] && cp -p "$REALM_PROTOCOL_FILE" "$backup_dir/protocol"
    [[ -f "$REALM_SERVICE_FILE" ]] && cp -p "$REALM_SERVICE_FILE" "$backup_dir/realm.init"
    [[ -f "$REALM_BIN" ]] && cp -p "$REALM_BIN" "$backup_dir/realm"
    info "旧文件已备份到：$backup_dir"
}

check_takeover() {
    local force="$1"
    local unmanaged="no"
    local reason=()

    if [[ -f "$REALM_CONFIG" ]] && ! is_managed_file "$REALM_CONFIG"; then
        unmanaged="yes"
        reason+=("$REALM_CONFIG")
    fi
    if [[ -f "$REALM_SERVICE_FILE" ]] && ! is_managed_file "$REALM_SERVICE_FILE"; then
        unmanaged="yes"
        reason+=("$REALM_SERVICE_FILE")
    fi
    if is_managed_file "$REALM_CONFIG" && [[ ! -f "$REALM_STATE" || ! -f "$REALM_PROTOCOL_FILE" ]]; then
        unmanaged="yes"
        reason+=("托管状态文件缺失")
    fi
    [[ "$unmanaged" == "yes" ]] || return 0

    warn "检测到非本脚本管理或不完整的 Realm 文件：$(join_by ', ' "${reason[@]}")"
    if [[ "$force" != "yes" ]] && ! confirm "是否先备份，再由本脚本接管？" "no"; then
        die "已取消。若确认接管，可使用 --force。"
    fi
    create_backup
    return 10
}

collect_routes_interactively() {
    local state_file="$1"
    local listen remote
    while true; do
        prompt_value listen "本机监听端口或地址" "23456"
        prompt_value remote "目标地址（HOST:PORT）" ""
        append_route_to_state "$state_file" "$listen" "$remote" >/dev/null || continue
        confirm "继续添加一条规则？" "n" || break
    done
}

print_firewall_hint() {
    local protocol="$1"
    local id listen remote extra port
    local shown=()
    while IFS=$'\t' read -r id listen remote extra || [[ -n "${id:-}" ]]; do
        [[ -z "${id:-}" || "$id" == \#* ]] && continue
        port="${listen##*:}"
        shown+=("$port")
    done <"$REALM_STATE"
    warn "请确认云安全组/系统防火墙已放行监听端口：$(join_by ', ' "${shown[@]}")（协议：$protocol）。"
}

realm_prepare() {
    require_root
    require_alpine
    require_openrc
    realm_install_dependencies
}

install_command() {
    local listen="" remote="" protocol="" version="latest" force="no"
    local takeover_result=0 fresh="yes" tmp_dir candidate_state candidate_config protocol_source route_id

    while (($#)); do
        case "$1" in
            --listen) (($# >= 2)) || die "--listen 缺少参数。"; listen="$2"; shift 2 ;;
            --remote) (($# >= 2)) || die "--remote 缺少参数。"; remote="$2"; shift 2 ;;
            --protocol) (($# >= 2)) || die "--protocol 缺少参数。"; protocol="${2,,}"; shift 2 ;;
            --version) (($# >= 2)) || die "--version 缺少参数。"; version="$2"; shift 2 ;;
            --force) force="yes"; shift ;;
            -h|--help) realm_usage; return 0 ;;
            *) die "未知 install 参数：$1" ;;
        esac
    done
    [[ -z "$listen" && -z "$remote" || -n "$listen" && -n "$remote" ]] || die "--listen 与 --remote 必须同时提供。"
    [[ -z "$protocol" ]] || validate_protocol "$protocol" || return 1

    realm_prepare
    install -d -m 0755 "$REALM_DIR"

    check_takeover "$force" || takeover_result=$?
    [[ "$takeover_result" == "10" ]] && fresh="yes"
    if is_managed_file "$REALM_CONFIG" && [[ -f "$REALM_STATE" && -f "$REALM_PROTOCOL_FILE" ]]; then
        fresh="no"
    fi

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate_state="$tmp_dir/routes.tsv"
    candidate_config="$tmp_dir/config.toml"
    protocol_source="$tmp_dir/protocol"
    if [[ "$fresh" == "no" ]]; then
        cp "$REALM_STATE" "$candidate_state"
        [[ -n "$protocol" ]] || protocol="$(read_protocol)"
    else
        printf '# id\tlisten\tremote\n' >"$candidate_state"
        if [[ -z "$protocol" ]]; then
            if can_prompt; then
                prompt_value protocol "转发协议（tcp/udp/both）" "both"
                protocol="${protocol,,}"
            else
                protocol="both"
            fi
        fi
    fi
    validate_protocol "$protocol" || return 1

    if [[ -n "$listen" ]]; then
        route_id="$(append_route_to_state "$candidate_state" "$listen" "$remote")" || return 1
        info "已准备规则 ID ${route_id}。"
    elif [[ "$fresh" == "yes" ]]; then
        collect_routes_interactively "$candidate_state"
    fi
    (($(route_count "$candidate_state") > 0)) || die "至少需要一条转发规则。"
    render_config "$candidate_state" "$protocol" "$candidate_config"
    printf '%s\n' "$protocol" >"$protocol_source"

    if [[ "$fresh" == "no" ]]; then
        replace_binary "$version" "yes" || die "安装未完成；旧版 Realm 已恢复。"
        install_service || die "安装未完成；已恢复原服务文件。"
        apply_configuration "$candidate_state" "$protocol" || die "安装未完成；原配置已恢复。"
    else
        replace_binary "$version" "no"
        install -m 0600 "$candidate_state" "$REALM_STATE"
        install -m 0644 "$protocol_source" "$REALM_PROTOCOL_FILE"
        install -m 0644 "$candidate_config" "$REALM_CONFIG"
        install_service || die "安装未完成；已恢复原服务文件（如有）。"
    fi

    info "Realm 安装完成并已设置开机自启。"
    "$REALM_BIN" --version || true
    list_command
    print_firewall_hint "$protocol"
}

ensure_managed_install() {
    is_installed || die "尚未完整安装 Realm，请先运行：bash alpine.sh realm install"
    is_managed_file "$REALM_CONFIG" || die "现有配置不由本脚本管理；请使用 install --force 备份并接管。"
    is_managed_file "$REALM_SERVICE_FILE" || die "现有服务不由本脚本管理；请使用 install --force 备份并接管。"
}

add_command() {
    local listen="" remote="" tmp_dir candidate route_id
    while (($#)); do
        case "$1" in
            --listen) (($# >= 2)) || die "--listen 缺少参数。"; listen="$2"; shift 2 ;;
            --remote) (($# >= 2)) || die "--remote 缺少参数。"; remote="$2"; shift 2 ;;
            -h|--help) realm_usage; return 0 ;;
            *) die "未知 add 参数：$1" ;;
        esac
    done
    realm_prepare
    ensure_managed_install
    [[ -n "$listen" ]] || prompt_value listen "本机监听端口或地址" "23456"
    [[ -n "$remote" ]] || prompt_value remote "目标地址（HOST:PORT）" ""

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate="$tmp_dir/routes.tsv"
    cp "$REALM_STATE" "$candidate"
    route_id="$(append_route_to_state "$candidate" "$listen" "$remote")" || return 1
    apply_configuration "$candidate" "$(read_protocol)" || die "添加失败；原配置已恢复。"
    info "已添加规则 ID ${route_id}。"
    list_command
}

edit_command() {
    local id="" listen="" remote="" tmp_dir candidate current_listen current_remote
    while (($#)); do
        case "$1" in
            --listen) (($# >= 2)) || die "--listen 缺少参数。"; listen="$2"; shift 2 ;;
            --remote) (($# >= 2)) || die "--remote 缺少参数。"; remote="$2"; shift 2 ;;
            -h|--help) realm_usage; return 0 ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ && -z "$id" ]]; then
                    id="$1"
                    shift
                else
                    die "未知 edit 参数：$1"
                fi
                ;;
        esac
    done
    realm_prepare
    ensure_managed_install

    if [[ -z "$id" ]]; then
        list_command
        prompt_value id "要编辑的规则 ID" ""
    fi
    [[ "$id" =~ ^[0-9]+$ ]] || { error "请提供要编辑的数字 ID。"; return 1; }
    read_route "$REALM_STATE" "$id" || die "未找到规则 ID：$id"
    current_listen="$ROUTE_LISTEN"
    current_remote="$ROUTE_REMOTE"

    if [[ -z "$listen" ]]; then
        if can_prompt; then
            prompt_value listen "本机监听端口或地址" "$current_listen"
        fi
    fi
    if [[ -z "$remote" ]]; then
        if can_prompt; then
            prompt_value remote "目标地址（HOST:PORT）" "$current_remote"
        fi
    fi
    if [[ -z "$listen" && -z "$remote" ]]; then
        die "请指定 --listen 和/或 --remote。"
    fi

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate="$tmp_dir/routes.tsv"
    cp "$REALM_STATE" "$candidate"
    update_route_in_state "$candidate" "$id" "$listen" "$remote" >/dev/null || return 1
    apply_configuration "$candidate" "$(read_protocol)" || die "编辑失败；原配置已恢复。"
    info "已更新规则 ID ${id}。"
    list_command
}

delete_command() {
    local id="${1:-}" tmp_dir candidate
    realm_prepare
    ensure_managed_install
    [[ "$id" =~ ^[0-9]+$ ]] || { error "请提供要删除的数字 ID。"; return 1; }

    realm_temp_dir
    tmp_dir="$LAST_TEMP_DIR"
    candidate="$tmp_dir/routes.tsv"
    cp "$REALM_STATE" "$candidate"
    delete_route_from_state "$candidate" "$id" || die "未找到规则 ID：$id"
    (($(route_count "$candidate") > 0)) || die "不能删除最后一条规则；如需停用请执行 uninstall。"

    apply_configuration "$candidate" "$(read_protocol)" || die "删除失败；原配置已恢复。"
    info "已删除原规则 ID ${id}，剩余规则已重新编号。"
    list_command
}

protocol_command() {
    local protocol="${1:-}"
    realm_prepare
    ensure_managed_install
    [[ -n "$protocol" ]] || prompt_value protocol "转发协议（tcp/udp/both）" "$(read_protocol)"
    protocol="${protocol,,}"
    validate_protocol "$protocol" || return 1
    apply_configuration "$REALM_STATE" "$protocol" || die "协议修改失败；原配置已恢复。"
    info "全部规则的协议已设为：$protocol"
    print_firewall_hint "$protocol"
}

list_command() {
    local id listen remote extra count=0
    [[ -f "$REALM_STATE" ]] || { warn "暂无规则状态文件。"; return 0; }
    printf '\n%-6s %-28s %s\n' "ID" "监听地址" "目标地址"
    printf '%-6s %-28s %s\n' "------" "----------------------------" "----------------------------"
    while IFS=$'\t' read -r id listen remote extra || [[ -n "${id:-}" ]]; do
        [[ -z "${id:-}" || "$id" == \#* ]] && continue
        printf '%-6s %-28s %s\n' "$id" "$listen" "$remote"
        ((count += 1))
    done <"$REALM_STATE"
    printf '协议：%s；共 %d 条规则。\n\n' "$(read_protocol)" "$count"
}

status_command() {
    require_root
    require_alpine
    require_openrc
    if [[ -x "$REALM_BIN" ]]; then
        "$REALM_BIN" --version || true
    else
        warn "未找到 Realm：$REALM_BIN"
    fi
    list_command
    if command_exists rc-service; then
        rc-service "$REALM_SERVICE_NAME" status || true
    fi
}

logs_command() {
    require_root
    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        tail -f "$REALM_LOG"
    else
        tail -n 100 "$REALM_LOG" 2>/dev/null || warn "没有日志：${REALM_LOG}"
    fi
}

update_command() {
    local version="latest"
    while (($#)); do
        case "$1" in
            --version) (($# >= 2)) || die "--version 缺少参数。"; version="$2"; shift 2 ;;
            -h|--help) realm_usage; return 0 ;;
            *) die "未知 update 参数：$1" ;;
        esac
    done
    realm_prepare
    ensure_managed_install
    replace_binary "$version" "yes" || die "更新失败；旧版本已恢复。"
    info "Realm 更新完成。"
    "$REALM_BIN" --version
}

uninstall_command() {
    local purge="no" assume_yes="no"
    while (($#)); do
        case "$1" in
            --purge) purge="yes"; shift ;;
            -y|--yes) assume_yes="yes"; ASSUME_YES=1; shift ;;
            -h|--help) realm_usage; return 0 ;;
            *) die "未知 uninstall 参数：$1" ;;
        esac
    done
    require_root
    require_alpine
    require_openrc
    if [[ "$assume_yes" != "yes" ]] && ! confirm "确认停止并卸载 Realm 服务？" "n"; then
        die "已取消卸载。"
    fi

    service_stop "$REALM_SERVICE_NAME"
    service_disable "$REALM_SERVICE_NAME"
    if is_managed_file "$REALM_SERVICE_FILE"; then
        rm -f -- "$REALM_SERVICE_FILE"
    else
        warn "服务文件不是由本脚本管理，未删除：$REALM_SERVICE_FILE"
    fi
    rm -f -- "$REALM_BIN" "$REALM_LOG"

    if [[ "$purge" == "yes" ]]; then
        if [[ "$assume_yes" == "yes" ]] || confirm "同时永久删除配置目录 ${REALM_DIR}？" "n"; then
            [[ "$REALM_DIR" == "/etc/realm" || "$REALM_DIR" == /tmp/* ]] || die "拒绝清理非预期配置目录：$REALM_DIR"
            rm -rf -- "$REALM_DIR"
            info "Realm 服务、程序和配置均已删除。"
            return 0
        fi
    fi
    info "Realm 服务和程序已删除；配置保留在：$REALM_DIR"
}

realm_menu() {
    local choice
    while true; do
        echo
        printf '%sRealm 端口转发管理器 v%s (OpenRC)%s\n' "$C_BLUE" "$REALM_SCRIPT_VERSION" "$C_RESET"
        cat <<'EOF'
────────────────────────────────────────
  1) 安装/修复 Realm
  2) 添加转发规则
  3) 编辑转发规则
  4) 删除转发规则
  5) 查看规则与状态
  6) 修改全局协议
  7) 更新 Realm
  8) 查看日志
  9) 卸载（保留配置）
  0) 返回主菜单
────────────────────────────────────────
EOF
        ask choice "请选择: "
        case "$choice" in
            1) install_command; pause ;;
            2) add_command; pause ;;
            3) edit_command; pause ;;
            4)
                list_command
                ask choice "请输入要删除的规则 ID: "
                delete_command "$choice"
                pause
                ;;
            5) status_command; pause ;;
            6) protocol_command; pause ;;
            7) update_command; pause ;;
            8) logs_command; pause ;;
            9) uninstall_command; pause ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

realm_main() {
    local command="${1:-menu}"
    (($# == 0)) || shift
    case "$command" in
        menu) realm_menu "$@" ;;
        install) install_command "$@" ;;
        add) add_command "$@" ;;
        edit) edit_command "$@" ;;
        delete|remove|rm) delete_command "$@" ;;
        protocol) protocol_command "$@" ;;
        list|ls) list_command "$@" ;;
        status) status_command "$@" ;;
        logs|log) logs_command "$@" ;;
        update|upgrade) update_command "$@" ;;
        uninstall) uninstall_command "$@" ;;
        help|-h|--help) realm_usage ;;
        *) error "未知命令：$command"; realm_usage; return 1 ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    realm_main "$@"
fi
