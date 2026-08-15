#!/usr/bin/env bash
# Shared helpers for Alpine Optimize. Safe to source multiple times.

if [[ -n "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
ALPINE_OPTIMIZE_COMMON=1

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
umask 022

SCRIPT_VERSION="${SCRIPT_VERSION:-1.0.0}"
PROJECT_NAME="${PROJECT_NAME:-Alpine Optimize}"

OS_ID=""
OS_NAME=""
MEM_MB=0
PRIMARY_IFACE=""
VIRT_KIND="none"
VIRT_TECH="none"
TEMP_PATHS=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    if command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
        C_RESET="$(tput sgr0)"
        C_BOLD="$(tput bold)"
        C_RED="$(tput setaf 1)"
        C_GREEN="$(tput setaf 2)"
        C_YELLOW="$(tput setaf 3)"
        C_BLUE="$(tput setaf 6)"
        C_DIM="$(tput setaf 8)"
    else
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[36m'
        C_DIM=$'\033[2m'
    fi
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

info()  { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[提醒]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
title() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { err "$*"; exit 1; }

# Compatibility aliases used by the upstream scripts.
log_info()    { info "$@"; }
log_success() { ok "$@"; }
log_warn()    { warn "$@"; }
log_error()   { err "$@"; }
error()       { err "$@"; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

iso_now() {
    date -Is 2>/dev/null || date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

join_by() {
    local separator="$1"
    shift
    local result="" item
    for item in "$@"; do
        [[ -z "$result" ]] || result+="$separator"
        result+="$item"
    done
    printf '%s\n' "$result"
}

can_prompt() {
    [[ -e /dev/tty ]] && { : </dev/tty; } 2>/dev/null
}

# Interactive prompts must read the real terminal. curl|bash leaves stdin on the
# pipe, so a normal `read` immediately gets EOF and menus spin on "无效选择".
ask() {
    local destvar="$1"
    local prompt="${2:-}"
    local reply=""

    if [[ -e /dev/tty ]]; then
        [[ -n "$prompt" ]] && printf '%s' "$prompt" >/dev/tty
        IFS= read -r reply </dev/tty || true
    else
        [[ -n "$prompt" ]] && printf '%s' "$prompt"
        IFS= read -r reply || true
    fi
    printf -v "$destvar" '%s' "$reply"
}

confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local answer hint

    if [[ "${ASSUME_YES:-0}" == "1" || "${ASSUME_YES:-}" == "yes" ]]; then
        return 0
    fi
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        [[ "$default" == "y" || "$default" == "yes" ]] && return 0
        return 1
    fi

    if [[ "$default" == "y" || "$default" == "yes" ]]; then
        hint=" [Y/n]: "
    else
        hint=" [y/N]: "
    fi
    ask answer "${prompt}${hint}"
    if [[ -z "$answer" ]]; then
        [[ "$default" == "y" || "$default" == "yes" ]] && return 0
        return 1
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_value() {
    local variable="$1"
    local message="$2"
    local default_value="${3:-}"
    local reply=""

    can_prompt || die "当前环境不能交互输入，请使用命令行参数。"
    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$message" "$default_value" >/dev/tty
    else
        printf '%s: ' "$message" >/dev/tty
    fi
    IFS= read -r reply </dev/tty || true
    printf -v "$variable" '%s' "${reply:-$default_value}"
}

require_root() {
    if [[ "${ALPINE_OPTIMIZE_SKIP_ROOT_CHECK:-0}" == "1" || "${REALM_SKIP_ROOT_CHECK:-0}" == "1" ]]; then
        return 0
    fi
    ((EUID == 0)) || die "请使用 root 运行。Alpine 通常直接以 root 登录：bash alpine.sh"
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || die "此脚本只能在 Linux 上运行。"
}

is_alpine() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi
    [[ "$id" == "alpine" || "$like" == *"alpine"* ]]
}

require_alpine() {
    [[ "${ALPINE_OPTIMIZE_SKIP_OS_CHECK:-0}" == "1" ]] && return 0
    require_linux
    if ! is_alpine && ! command_exists apk; then
        die "这是 Alpine Linux 聚合脚本。Debian/Ubuntu 请使用各子项目原脚本（nanami-vps-optimize / realm.sh / socks5.sh / sing-box-plus.sh）。"
    fi
    if ! is_alpine; then
        warn "当前系统不是标准 Alpine，但检测到 apk，将按 Alpine 方式继续。"
    fi
}

require_openrc() {
    [[ "${ALPINE_OPTIMIZE_SKIP_OS_CHECK:-0}" == "1" ]] && return 0
    if ! command_exists rc-service && ! command_exists rc-update && [[ ! -f /sbin/openrc-run ]]; then
        die "未检测到 OpenRC。此聚合脚本面向 Alpine / OpenRC。"
    fi
}

pause() {
    [[ "${NONINTERACTIVE:-0}" == "1" ]] && return 0
    echo
    if [[ -e /dev/tty ]]; then
        printf '按任意键继续...' >/dev/tty
        IFS= read -r -n 1 -s _ </dev/tty || true
        printf '\n' >/dev/tty
    else
        printf '按任意键继续...'
        IFS= read -r -n 1 -s _ || true
        echo
    fi
}

register_temp() {
    TEMP_PATHS+=("$1")
}

cleanup_temps() {
    local path
    for path in "${TEMP_PATHS[@]:-}"; do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -rf -- "$path"
        fi
    done
}

new_temp_dir() {
    local dir
    dir="$(mktemp -d)"
    register_temp "$dir"
    printf '%s\n' "$dir"
}

write_file() {
    local path="$1"
    local mode="${2:-0644}"
    local dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.tmp.XXXXXX")"
    register_temp "$tmp"
    cat >"$tmp"
    chmod "$mode" "$tmp"
    if ((EUID == 0)); then
        chown root:root "$tmp" 2>/dev/null || true
    fi
    mv -f -- "$tmp" "$path"
}

backup_if_exists() {
    local file="$1"
    if [[ -e "$file" && ! -e "${file}.alpine.bak" ]]; then
        cp -a "$file" "${file}.alpine.bak"
        dim "已备份：${file} -> ${file}.alpine.bak"
    fi
}

replace_managed_block() {
    local file="$1"
    local begin="$2"
    local end="$3"
    local content="$4"
    local tmp

    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : >"$file"
    tmp="$(mktemp)"
    register_temp "$tmp"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$file" >"$tmp"
    {
        cat "$tmp"
        printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
    } >"${tmp}.out"
    mv -f "${tmp}.out" "$file"
    rm -f "$tmp"
}

remove_managed_block() {
    local file="$1"
    local begin="$2"
    local end="$3"
    local tmp
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)"
    register_temp "$tmp"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$file" >"$tmp"
    mv -f "$tmp" "$file"
}

enable_community_repo() {
    local repo_file="${1:-/etc/apk/repositories}"
    [[ -f "$repo_file" ]] || return 0

    if grep -qE '^[[:space:]]*#[[:space:]]*https?://.*/community[[:space:]]*$' "$repo_file" 2>/dev/null; then
        info "正在启用 Alpine community 软件源。"
        sed -i -E 's|^[[:space:]]*#[[:space:]]*(https?://.*/community)[[:space:]]*$|\1|' "$repo_file"
    elif ! grep -qE '^[[:space:]]*https?://.*/community[[:space:]]*$' "$repo_file" 2>/dev/null; then
        local main_url community_url
        main_url="$(grep -E '^[[:space:]]*https?://.*/main[[:space:]]*$' "$repo_file" 2>/dev/null | head -n 1 | awk '{print $1}' || true)"
        if [[ -n "$main_url" ]]; then
            community_url="${main_url%/main}/community"
            info "正在添加 Alpine community 软件源：${community_url}"
            printf '%s\n' "$community_url" >>"$repo_file"
        fi
    fi
}

apk_add() {
    command_exists apk || die "未检测到 apk 包管理器。"
    apk add --no-cache "$@"
}

ensure_packages() {
    local -a missing=()
    local pkg
    [[ "${ALPINE_OPTIMIZE_SKIP_OS_CHECK:-0}" == "1" ]] && return 0
    command_exists apk || die "未检测到 apk 包管理器。"

    for pkg in "$@"; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    ((${#missing[@]} == 0)) && return 0

    enable_community_repo
    info "安装软件包：${missing[*]}"
    apk_add "${missing[@]}"
}

detect_virt() {
    local vendor product cgroup1
    VIRT_KIND="none"
    VIRT_TECH="none"

    if [[ -f /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -q '^container='; then
        VIRT_KIND="container"
        VIRT_TECH="$(tr '\0' '\n' </proc/1/environ 2>/dev/null | awk -F= '$1=="container"{print $2; exit}')"
        VIRT_TECH="${VIRT_TECH:-container}"
    fi

    if [[ -d /proc/vz && ! -d /proc/bc ]]; then
        VIRT_KIND="container"
        VIRT_TECH="openvz"
    fi

    cgroup1="$(cat /proc/1/cgroup 2>/dev/null || true)"
    if [[ "$cgroup1" == *docker* || "$cgroup1" == *lxc* || "$cgroup1" == *kubepods* || "$cgroup1" == *containerd* ]]; then
        VIRT_KIND="container"
        [[ "$VIRT_TECH" == "none" ]] && VIRT_TECH="cgroup"
    fi

    if [[ "$VIRT_KIND" != "container" ]]; then
        vendor="$(tr -d '\0' </sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
        product="$(tr -d '\0' </sys/class/dmi/id/product_name 2>/dev/null || true)"
        case "${vendor,,} ${product,,}" in
            *qemu*|*kvm*|*bochs*) VIRT_KIND="vm"; VIRT_TECH="kvm" ;;
            *xen*) VIRT_KIND="vm"; VIRT_TECH="xen" ;;
            *vmware*) VIRT_KIND="vm"; VIRT_TECH="vmware" ;;
            *microsoft*|*hyper-v*) VIRT_KIND="vm"; VIRT_TECH="hyperv" ;;
            *google*) VIRT_KIND="vm"; VIRT_TECH="gce" ;;
            *amazon*|*ec2*) VIRT_KIND="vm"; VIRT_TECH="ec2" ;;
            *digitalocean*) VIRT_KIND="vm"; VIRT_TECH="digitalocean" ;;
        esac
        if [[ "$VIRT_KIND" == "none" ]] && grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
            VIRT_KIND="vm"
            VIRT_TECH="hypervisor"
        fi
    fi
}

detect_system() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
    else
        OS_ID="unknown"
        OS_NAME="Linux"
    fi

    MEM_MB="$(awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)"
    detect_virt

    if command_exists ip; then
        PRIMARY_IFACE="$(ip -o -4 route show to default 2>/dev/null \
            | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' \
            | cut -d'@' -f1)"
        if [[ -z "$PRIMARY_IFACE" ]]; then
            PRIMARY_IFACE="$(ip -o link show up 2>/dev/null \
                | awk -F': ' '$2 != "lo" {gsub(/@.*/, "", $2); print $2; exit}')"
        fi
    fi
}

is_container() {
    [[ "$VIRT_KIND" == "container" ]]
}

is_valid_port() {
    local value=${1:-}
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$value >= 1 && 10#$value <= 65535))
}

is_valid_ipv4() {
    local address=${1:-}
    local -a octets=()
    local octet

    IFS='.' read -r -a octets <<<"$address"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

is_valid_host() {
    local value=${1:-}
    [[ -n "$value" && ${#value} -le 255 ]] || return 1
    if is_valid_ipv4 "$value"; then
        return 0
    fi
    [[ "$value" =~ ^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9])(\.([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]))*$ ]]
}

random_hex() {
    local length=$1
    local byte_count raw
    byte_count=$(((length + 1) / 2))
    raw="$(od -An -N "$byte_count" -tx1 /dev/urandom | tr -d '[:space:]')"
    printf '%s\n' "${raw:0:length}"
}

port_in_use() {
    local port=$1
    local port_hex

    if command_exists ss; then
        ss -H -ltun 2>/dev/null | awk -v expected="$port" '
            {
                address = $5
                if (address == "") address = $4
                sub(/^.*:/, "", address)
                if (address == expected) found = 1
            }
            END { exit found ? 0 : 1 }
        '
        return
    fi

    printf -v port_hex '%04X' "$port"
    awk -v expected=":${port_hex}" '
        NR > 1 && index($2, expected) == length($2) - length(expected) + 1 && $4 == "0A" {
            found = 1
        }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

choose_random_port() {
    local attempt random_value candidate
    for ((attempt = 0; attempt < 128; attempt++)); do
        random_value="$(od -An -N 2 -tu2 /dev/urandom | tr -d '[:space:]')"
        candidate=$((20000 + random_value % 40001))
        if ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

discover_public_ipv4() {
    local public_ip=""
    if command_exists curl; then
        public_ip="$(curl --noproxy '*' -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    fi
    if is_valid_ipv4 "$public_ip"; then
        printf '%s\n' "$public_ip"
        return 0
    fi
    public_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, parts, "/"); print parts[1] }')"
    if is_valid_ipv4 "$public_ip"; then
        printf '%s\n' "$public_ip"
    else
        printf '%s\n' "<VPS_PUBLIC_IP>"
    fi
}

service_is_active() {
    local svc=$1
    if command_exists rc-service; then
        rc-service "$svc" status >/dev/null 2>&1
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" status >/dev/null 2>&1
    else
        return 1
    fi
}

service_start() {
    local svc=$1
    if command_exists rc-service; then
        rc-service "$svc" start
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" start
    else
        return 1
    fi
}

service_restart() {
    local svc=$1
    if command_exists rc-service; then
        rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" restart >/dev/null 2>&1 || "/etc/init.d/$svc" start
    else
        return 1
    fi
}

service_stop() {
    local svc=$1
    if command_exists rc-service; then
        rc-service "$svc" stop >/dev/null 2>&1 || true
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" stop >/dev/null 2>&1 || true
    fi
}

service_enable() {
    local svc=$1
    if command_exists rc-update; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
    fi
}

service_disable() {
    local svc=$1
    if command_exists rc-update; then
        rc-update del "$svc" default >/dev/null 2>&1 || rc-update del "$svc" >/dev/null 2>&1 || true
    fi
}

reload_sshd() {
    if command_exists sshd && ! sshd -t >/dev/null 2>&1; then
        return 1
    fi
    if command_exists rc-service; then
        rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
    fi
}

swap_total_mb() {
    awk '/^Swap:/ { print int($2) }' < <(free -m 2>/dev/null) 2>/dev/null || awk '/^SwapTotal:/ { print int($2 / 1024) }' /proc/meminfo
}

short_hostname() {
    local name
    name="$(uname -n 2>/dev/null || echo vps)"
    printf '%s\n' "${name%%.*}"
}

ensure_nologin_shell() {
    if [[ -x /sbin/nologin ]]; then
        printf '%s\n' /sbin/nologin
    elif command_exists nologin; then
        command -v nologin
    else
        printf '%s\n' /bin/false
    fi
}

ensure_system_user() {
    local user="$1"
    local shell
    shell="$(ensure_nologin_shell)"
    if ! getent passwd "$user" >/dev/null 2>&1; then
        if command_exists addgroup && ! getent group "$user" >/dev/null 2>&1; then
            addgroup -S "$user" >/dev/null
        fi
        if command_exists adduser; then
            adduser -S -D -H -s "$shell" -G "$user" "$user" >/dev/null
        else
            die "找不到 adduser，无法创建系统账号 ${user}。"
        fi
    fi
}

sha256_file() {
    local file="$1"
    if command_exists sha256sum; then
        sha256sum "$file" | awk '{ print $1 }'
    elif command_exists shasum; then
        shasum -a 256 "$file" | awk '{ print $1 }'
    elif command_exists openssl; then
        openssl dgst -sha256 "$file" | awk '{ print $NF }'
    else
        die "未找到 sha256sum 或 openssl。"
    fi
}

detect_goarch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7) printf 'armv7\n' ;;
        i386|i686) printf '386\n' ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

ensure_crond() {
    [[ "${ALPINE_OPTIMIZE_SKIP_OS_CHECK:-0}" == "1" ]] && return 0
    if ! command_exists crond && ! command_exists cron; then
        ensure_packages busybox-extras || true
    fi
    if [[ -x /etc/init.d/crond ]]; then
        service_enable crond
        service_is_active crond || service_start crond >/dev/null 2>&1 || true
    fi
}
