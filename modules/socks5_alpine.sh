#!/usr/bin/env bash

# If executed via /bin/sh on Alpine, attempt to re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "正在通过 apk 安装 bash..." >&2
            apk update >/dev/null 2>&1 && apk add --no-cache bash >/dev/null 2>&1 || {
                echo "错误：无法自动安装 bash，请先手动执行 apk add bash" >&2
                exit 1
            }
        else
            echo "错误：运行此脚本需要 bash 解释器。" >&2
            exit 1
        fi
    fi
    if [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
fi

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_VERSION="1.0.1"
APP_NAME="socks5-node"
CONFIG_DIR="/etc/${APP_NAME}"
STATE_FILE="${CONFIG_DIR}/state.env"
DANTE_CONFIG_DIR="/etc/socks"
DANTE_CONFIG_FILE="${DANTE_CONFIG_DIR}/${APP_NAME}.conf"
FIREWALL_HELPER="/usr/local/sbin/${APP_NAME}-firewall"
SERVICE_INIT="/etc/init.d/${APP_NAME}"
FIREWALL_INIT="/etc/init.d/${APP_NAME}-firewall"
LOG_FILE="/var/log/${APP_NAME}.log"

ACTION="install"
ASSUME_YES=0
CONFIG_OVERRIDES=0
CLI_FORCE=0
CLI_PORT=""
CLI_USERNAME=""
CLI_PASSWORD=""
CLI_ALLOW_CIDR=""
CLI_ALLOW_PRIVATE=0
CLI_DISABLE_FIREWALL=0
CLI_HOST=""
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/modules/socks5_alpine.sh"

SOCKS_PORT=""
SOCKS_USERNAME=""
SOCKS_PASSWORD=""
PUBLIC_HOST="${PUBLIC_HOST:-}"
ALLOW_CIDR="0.0.0.0/0"
ALLOW_PRIVATE=0
EXTERNAL_INTERFACE=""
DANTE_BIN=""
FIREWALL_BACKEND="none"
FIREWALL_ZONE=""
AUTH_GROUP=""
AUTH_GROUP_GID=""
AUTH_USER_UID=""
DAEMON_USER=""
DAEMON_USER_UID=""
DAEMON_GROUP=""
DAEMON_GROUP_GID=""
INSTALLED_AT=""
DANTE_WAS_PRESENT=0
DANTE_CONFIG_DIR_CREATED=0
SELINUX_ENABLED=0
SELINUX_PORT_MANAGED=0

ROLLBACK_ACTIVE=0
AUTH_USER_CREATED=0
AUTH_GROUP_CREATED=0
DAEMON_USER_CREATED=0
DAEMON_GROUP_CREATED=0
TEMP_FILES=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_BOLD=$'\033[1m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_BOLD=""
    COLOR_RESET=""
fi

log_info() {
    printf '%s[信息]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_success() {
    printf '%s[完成]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[提醒]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
    printf '%s[错误]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

usage() {
    cat <<'EOF'
Alpine Linux SOCKS5 一键安装脚本 (OpenRC)

用法：
  bash socks5_alpine.sh [install] [选项]
  bash socks5_alpine.sh info
  bash socks5_alpine.sh uninstall [--yes]

安装选项：
  -p, --port PORT          指定监听端口；默认在 20000-60000 中随机选择
  -H, --host HOST          指定连接入口地址（IPv4 或域名，用于 NAT VPS）
  -u, --username USER      指定认证用户名；默认随机生成
  -P, --password PASS      指定认证密码；默认随机生成
      --allow-cidr CIDR    只允许指定 IPv4/CIDR 连接；默认 0.0.0.0/0
      --allow-private      允许代理访问内网、环回及链路本地地址
      --no-firewall        不修改 VPS 操作系统防火墙
  -f, --force, --reinstall 覆盖已有的旧节点安装
  -y, --yes                跳过卸载确认
  -h, --help               显示帮助
      --version            显示版本

密码只能包含英文字母、数字、点、下划线和短横线，长度为 12-128。
EOF
}

cleanup_temp_files() {
    local temp_file

    for temp_file in "${TEMP_FILES[@]:-}"; do
        if [[ -n "$temp_file" && -f "$temp_file" ]]; then
            rm -f -- "$temp_file"
        fi
    done
}

service_is_active() {
    local svc=${1:-$APP_NAME}
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" status >/dev/null 2>&1
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" status >/dev/null 2>&1
    else
        return 1
    fi
}

service_restart() {
    local svc=${1:-$APP_NAME}
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" restart >/dev/null 2>&1 || rc-service "$svc" start >/dev/null 2>&1
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" restart >/dev/null 2>&1 || "/etc/init.d/$svc" start >/dev/null 2>&1
    else
        return 1
    fi
}

service_stop() {
    local svc=${1:-$APP_NAME}
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop >/dev/null 2>&1 || true
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" stop >/dev/null 2>&1 || true
    fi
}

service_enable() {
    local svc=${1:-$APP_NAME}
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
    fi
}

service_disable() {
    local svc=${1:-$APP_NAME}
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default >/dev/null 2>&1 || rc-update del "$svc" >/dev/null 2>&1 || true
    fi
}

rollback_install() {
    log_warn "安装没有完成，正在回滚本次新建的服务、防火墙规则和账号。"
    set +e

    service_stop "${APP_NAME}"
    service_stop "${APP_NAME}-firewall"
    service_disable "${APP_NAME}"
    service_disable "${APP_NAME}-firewall"

    if [[ -x "$FIREWALL_HELPER" ]]; then
        "$FIREWALL_HELPER" remove >/dev/null 2>&1
    fi

    rm -f -- "$SERVICE_INIT" "$FIREWALL_INIT" "$FIREWALL_HELPER" "$DANTE_CONFIG_FILE" "$LOG_FILE" "/usr/local/bin/${APP_NAME}"

    if ((AUTH_USER_CREATED == 1)) && id "$SOCKS_USERNAME" >/dev/null 2>&1; then
        remove_managed_user "$SOCKS_USERNAME" "$AUTH_USER_UID"
    fi
    if ((DAEMON_USER_CREATED == 1)) && id "$DAEMON_USER" >/dev/null 2>&1; then
        remove_managed_user "$DAEMON_USER" "$DAEMON_USER_UID"
    fi
    if ((AUTH_GROUP_CREATED == 1)) && getent group "$AUTH_GROUP" >/dev/null 2>&1; then
        remove_managed_group "$AUTH_GROUP" "$AUTH_GROUP_GID"
    fi
    if ((DAEMON_GROUP_CREATED == 1)) && getent group "$DAEMON_GROUP" >/dev/null 2>&1; then
        remove_managed_group "$DAEMON_GROUP" "$DAEMON_GROUP_GID"
    fi

    if [[ "$CONFIG_DIR" == "/etc/socks5-node" && -d "$CONFIG_DIR" ]]; then
        rm -rf -- "$CONFIG_DIR"
    fi
    if ((DANTE_CONFIG_DIR_CREATED == 1)) && [[ "$DANTE_CONFIG_DIR" == "/etc/socks" ]]; then
        rmdir -- "$DANTE_CONFIG_DIR" >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local exit_code=$?

    trap - EXIT
    cleanup_temp_files
    if ((exit_code != 0 && ROLLBACK_ACTIVE == 1)); then
        rollback_install
    fi
    exit "$exit_code"
}

if [[ "${SOCKS5_NODE_LIB_ONLY:-0}" != "1" ]]; then
    trap on_exit EXIT
fi

require_option_value() {
    local option=$1
    local remaining=$2

    ((remaining >= 2)) || die "选项 ${option} 缺少参数。"
}

parse_args() {
    if (($# > 0)); then
        case "$1" in
            install | info | uninstall)
                ACTION=$1
                shift
                ;;
            help)
                usage
                exit 0
                ;;
        esac
    fi

    while (($# > 0)); do
        case "$1" in
            -p | --port)
                require_option_value "$1" "$#"
                CLI_PORT=$2
                CONFIG_OVERRIDES=1
                shift 2
                ;;
            -H | --host | --server-host | --public-host | --domain | --public-ip)
                require_option_value "$1" "$#"
                CLI_HOST=$2
                CONFIG_OVERRIDES=1
                shift 2
                ;;
            -u | --username)
                require_option_value "$1" "$#"
                CLI_USERNAME=$2
                CONFIG_OVERRIDES=1
                shift 2
                ;;
            -P | --password)
                require_option_value "$1" "$#"
                CLI_PASSWORD=$2
                CONFIG_OVERRIDES=1
                shift 2
                ;;
            --allow-cidr)
                require_option_value "$1" "$#"
                CLI_ALLOW_CIDR=$2
                CONFIG_OVERRIDES=1
                shift 2
                ;;
            --allow-private)
                CLI_ALLOW_PRIVATE=1
                CONFIG_OVERRIDES=1
                shift
                ;;
            --no-firewall)
                CLI_DISABLE_FIREWALL=1
                CONFIG_OVERRIDES=1
                shift
                ;;
            -f | --force | --reinstall)
                CLI_FORCE=1
                shift
                ;;
            -y | --yes)
                ASSUME_YES=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s (Alpine OpenRC)\n' "$APP_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    if [[ -z "$CLI_PORT" && -n "${PORT:-}" ]]; then
        CLI_PORT="$PORT"
        CONFIG_OVERRIDES=1
    fi
    if [[ -z "$CLI_HOST" && -n "${HOST:-}" ]]; then
        CLI_HOST="$HOST"
        CONFIG_OVERRIDES=1
    elif [[ -z "$CLI_HOST" && -n "${PUBLIC_HOST:-}" ]]; then
        CLI_HOST="$PUBLIC_HOST"
        CONFIG_OVERRIDES=1
    elif [[ -z "$CLI_HOST" && -n "${SERVER_HOST:-}" ]]; then
        CLI_HOST="$SERVER_HOST"
        CONFIG_OVERRIDES=1
    fi

    if [[ "$ACTION" != "install" && $CONFIG_OVERRIDES -eq 1 ]]; then
        die "安装参数只能与 install 动作一起使用。"
    fi
}

is_valid_port() {
    local value=${1:-}

    [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$value >= 1025 && 10#$value <= 65535))
}

is_valid_username() {
    local value=${1:-}

    [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

is_valid_password() {
    local value=${1:-}

    [[ "$value" =~ ^[A-Za-z0-9._-]{12,128}$ ]]
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

is_valid_ipv4_cidr() {
    local value=${1:-}
    local address prefix

    [[ "$value" == */* ]] || return 1
    address=${value%/*}
    prefix=${value#*/}

    is_valid_ipv4 "$address" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    [[ "$prefix" == "0" || "$prefix" != 0* ]] || return 1
    ((10#$prefix <= 32))
}

normalize_ipv4_cidr() {
    local value=$1

    if [[ "$value" != */* ]]; then
        value="${value}/32"
    fi
    is_valid_ipv4_cidr "$value" || return 1
    printf '%s\n' "$value"
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
    raw=$(od -An -N "$byte_count" -tx1 /dev/urandom | tr -d '[:space:]')
    printf '%s\n' "${raw:0:length}"
}

port_in_use() {
    local port=$1
    local port_hex

    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk -v expected="$port" '
            {
                address = $4
                sub(/^.*:/, "", address)
                if (address == expected) {
                    found = 1
                }
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
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

wait_for_port_listen() {
    local port=$1
    local timeout_seconds=${2:-15}
    local deadline

    deadline=$(($(date +%s) + timeout_seconds))
    while (( $(date +%s) <= deadline )); do
        if port_in_use "$port"; then
            return 0
        fi
        if ! service_is_active "${APP_NAME}"; then
            return 1
        fi
        sleep 0.1
    done
    return 1
}

choose_random_port() {
    local attempt random_value candidate

    for ((attempt = 0; attempt < 128; attempt++)); do
        random_value=$(od -An -N 2 -tu2 /dev/urandom | tr -d '[:space:]')
        candidate=$((20000 + random_value % 40001))
        if ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

require_root_and_openrc() {
    [[ "$(uname -s)" == "Linux" ]] || die "此脚本只能在 Linux 上运行。"
    ((EUID == 0)) || die "请使用 root 用户运行此脚本，例如：bash socks5_alpine.sh"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "alpine" && "${ID_LIKE:-}" != *"alpine"* ]]; then
            log_warn "当前系统检测为 ${PRETTY_NAME:-${NAME:-Linux}}，非标准 Alpine Linux。"
        fi
    fi

    if ! command -v rc-service >/dev/null 2>&1 && ! command -v rc-update >/dev/null 2>&1 && [[ ! -f /sbin/openrc-run ]]; then
        die "当前系统未检测到 OpenRC（缺少 rc-service/rc-update）。如果是 systemd 系统，请使用 socks5.sh。"
    fi
}

acquire_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        log_warn "系统没有 flock，无法阻止两个安装进程同时运行。"
        return
    fi

    mkdir -p /run/lock
    exec 9>/run/lock/socks5-node.lock
    flock -n 9 || die "另一个 socks5-node 操作正在运行。"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || die "没有找到安装状态：${STATE_FILE}"

    SOCKS_PORT=""
    SOCKS_USERNAME=""
    SOCKS_PASSWORD=""
    PUBLIC_HOST=""
    ALLOW_CIDR=""
    ALLOW_PRIVATE=""
    EXTERNAL_INTERFACE=""
    DANTE_BIN=""
    FIREWALL_BACKEND=""
    FIREWALL_ZONE=""
    AUTH_GROUP=""
    AUTH_GROUP_GID=""
    AUTH_USER_UID=""
    DAEMON_USER=""
    DAEMON_USER_UID=""
    DAEMON_GROUP=""
    DAEMON_GROUP_GID=""
    INSTALLED_AT=""
    DANTE_WAS_PRESENT=0
    DANTE_CONFIG_DIR_CREATED=0
    SELINUX_ENABLED=0
    SELINUX_PORT_MANAGED=0

    # 状态文件仅 root 可写，并由本脚本以 shell 转义格式生成。
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    [[ "${STATE_VERSION:-}" == "1" ]] || die "不支持的状态文件版本。"
    is_valid_port "$SOCKS_PORT" || die "状态文件中的端口无效。"
    is_valid_username "$SOCKS_USERNAME" || die "状态文件中的用户名无效。"
    is_valid_password "$SOCKS_PASSWORD" || die "状态文件中的密码无效。"
    if [[ -n "$PUBLIC_HOST" ]]; then
        is_valid_host "$PUBLIC_HOST" || die "状态文件中的入口地址无效。"
    fi
    is_valid_ipv4_cidr "$ALLOW_CIDR" || die "状态文件中的允许网段无效。"
    [[ "$ALLOW_PRIVATE" == "0" || "$ALLOW_PRIVATE" == "1" ]] || die "状态文件中的私网选项无效。"
    [[ "$EXTERNAL_INTERFACE" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "状态文件中的出口网卡无效。"
    [[ "$DANTE_BIN" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "状态文件中的 Dante 路径无效。"
    case "$FIREWALL_BACKEND" in
        ufw | firewalld | iptables | nftables | none | disabled) ;;
        *) die "状态文件中的防火墙后端无效。" ;;
    esac
    [[ -z "$FIREWALL_ZONE" || "$FIREWALL_ZONE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "状态文件中的 firewalld zone 无效。"
    is_valid_username "$AUTH_GROUP" || die "状态文件中的认证用户组无效。"
    is_valid_username "$DAEMON_USER" || die "状态文件中的守护账号无效。"
    is_valid_username "$DAEMON_GROUP" || die "状态文件中的守护用户组无效。"
    [[ "$AUTH_USER_UID" =~ ^[0-9]+$ && "$AUTH_GROUP_GID" =~ ^[0-9]+$ ]] || die "状态文件中的认证账号 ID 无效。"
    [[ "$DAEMON_USER_UID" =~ ^[0-9]+$ && "$DAEMON_GROUP_GID" =~ ^[0-9]+$ ]] || die "状态文件中的守护账号 ID 无效。"
    [[ "$DANTE_CONFIG_DIR_CREATED" == "0" || "$DANTE_CONFIG_DIR_CREATED" == "1" ]] || die "状态文件中的配置目录标记无效。"
    [[ "$SELINUX_ENABLED" == "0" || "$SELINUX_ENABLED" == "1" ]] || die "状态文件中的 SELinux 标记无效。"
    [[ "$SELINUX_PORT_MANAGED" == "0" || "$SELINUX_PORT_MANAGED" == "1" ]] || die "状态文件中的 SELinux 端口标记无效。"
}

atomic_write() {
    local destination=$1
    local mode=$2
    local renderer=$3
    local temp_file

    temp_file=$(mktemp "${destination}.tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    "$renderer" >"$temp_file"
    chmod "$mode" "$temp_file"
    chown root:root "$temp_file"
    mv -f -- "$temp_file" "$destination"
}

enable_alpine_community_repo() {
    local repo_file="/etc/apk/repositories"
    [[ -f "$repo_file" ]] || return 0

    if grep -q '^#[^#]*/community$' "$repo_file" 2>/dev/null; then
        log_info "正在启用 Alpine community 软件源。"
        sed -i 's|^#\([^#]*/community\)$|\1|' "$repo_file"
    elif ! grep -q '/community$' "$repo_file" 2>/dev/null; then
        local main_url
        main_url=$(grep -E '^https?://.*/main$' "$repo_file" 2>/dev/null | head -n 1 || true)
        if [[ -n "$main_url" ]]; then
            local community_url="${main_url%/main}/community"
            log_info "正在添加 Alpine community 软件源：${community_url}"
            printf '%s\n' "$community_url" >> "$repo_file"
        fi
    fi
}

find_dante_binary() {
    if command -v sockd >/dev/null 2>&1; then
        command -v sockd
    elif command -v danted >/dev/null 2>&1; then
        command -v danted
    elif [[ -x /usr/sbin/sockd ]]; then
        printf '%s\n' "/usr/sbin/sockd"
    elif [[ -x /usr/sbin/danted ]]; then
        printf '%s\n' "/usr/sbin/danted"
    else
        return 1
    fi
}

install_dependencies() {
    local -a packages=()

    if DANTE_BIN=$(find_dante_binary); then
        DANTE_WAS_PRESENT=1
        log_info "检测到已有 Dante：${DANTE_BIN}，不会改动发行版自带配置。"
    fi

    if ! command -v apk >/dev/null 2>&1; then
        die "未检测到 apk 包管理器，此脚本仅适用于 Alpine Linux。"
    fi

    enable_alpine_community_repo
    apk update

    packages=(curl ca-certificates iproute2 bash shadow)
    if ((DANTE_WAS_PRESENT == 0)); then
        packages+=(dante-server)
    fi

    log_info "正在安装所需软件包：${packages[*]}"
    if ! apk add --no-cache "${packages[@]}"; then
        log_warn "部分软件包安装重试中..."
        apk add --no-cache curl ca-certificates iproute2 bash dante-server || die "安装依赖失败。"
    fi

    DANTE_BIN=$(find_dante_binary) || die "安装完成后仍找不到 sockd/danted。"
    command -v ip >/dev/null 2>&1 || die "找不到 ip 命令。"

    if ((DANTE_WAS_PRESENT == 0)); then
        service_stop sockd
        service_disable sockd
        service_stop danted
        service_disable danted
    fi
}

detect_external_interface() {
    local route_output interface

    route_output=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
    interface=$(awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<<"$route_output")

    if [[ -z "$interface" ]]; then
        interface=$(ip -4 route show default 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && (i + 1) <= NF) {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ')
    fi

    [[ "$interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "无法确定安全的 IPv4 出口网卡。"
    printf '%s\n' "$interface"
}

generate_managed_identities() {
    local attempt token requested_username

    requested_username=$CLI_USERNAME
    if [[ -n "$requested_username" ]]; then
        is_valid_username "$requested_username" || die "用户名格式无效：${requested_username}"
        getent passwd "$requested_username" >/dev/null 2>&1 && die "系统用户 ${requested_username} 已存在，请换一个用户名。"
    fi

    for ((attempt = 0; attempt < 64; attempt++)); do
        token=$(random_hex 8)
        SOCKS_USERNAME=${requested_username:-"s5u_${token}"}
        AUTH_GROUP="s5g_${token}"
        DAEMON_USER="s5d_${token}"
        DAEMON_GROUP=$DAEMON_USER

        if ! getent passwd "$SOCKS_USERNAME" >/dev/null 2>&1 \
            && ! getent group "$AUTH_GROUP" >/dev/null 2>&1 \
            && ! getent passwd "$DAEMON_USER" >/dev/null 2>&1 \
            && ! getent group "$DAEMON_GROUP" >/dev/null 2>&1; then
            return 0
        fi

        [[ -z "$requested_username" ]] || die "生成隔离账号时发生名称冲突，请重试。"
    done

    die "无法生成不冲突的系统账号。"
}

create_managed_accounts() {
    local nologin_shell

    nologin_shell=$(command -v nologin 2>/dev/null || true)
    if [[ -z "$nologin_shell" || ! -x "$nologin_shell" ]]; then
        if [[ -x /sbin/nologin ]]; then
            nologin_shell="/sbin/nologin"
        else
            nologin_shell="/bin/false"
        fi
    fi

    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system "$AUTH_GROUP"
    else
        addgroup -S "$AUTH_GROUP"
    fi
    AUTH_GROUP_CREATED=1
    AUTH_GROUP_GID=$(getent group "$AUTH_GROUP" | awk -F: '{print $3}')

    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system "$DAEMON_GROUP"
    else
        addgroup -S "$DAEMON_GROUP"
    fi
    DAEMON_GROUP_CREATED=1
    DAEMON_GROUP_GID=$(getent group "$DAEMON_GROUP" | awk -F: '{print $3}')

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid "$DAEMON_GROUP" --no-create-home --shell "$nologin_shell" "$DAEMON_USER"
    else
        adduser -S -D -H -s "$nologin_shell" -G "$DAEMON_GROUP" "$DAEMON_USER"
    fi
    DAEMON_USER_CREATED=1
    DAEMON_USER_UID=$(id -u "$DAEMON_USER")

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid "$AUTH_GROUP" --no-create-home --shell "$nologin_shell" "$SOCKS_USERNAME"
    else
        adduser -S -D -H -s "$nologin_shell" -G "$AUTH_GROUP" "$SOCKS_USERNAME"
    fi
    AUTH_USER_CREATED=1
    AUTH_USER_UID=$(id -u "$SOCKS_USERNAME")
    printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
}

render_dante_config() {
    local blocked_network
    local -a blocked_networks=(
        "0.0.0.0/8"
        "10.0.0.0/8"
        "100.64.0.0/10"
        "127.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "198.18.0.0/15"
        "224.0.0.0/4"
        "240.0.0.0/4"
    )

    cat <<EOF
# Managed by socks5-node. Manual changes may be overwritten.
logoutput: syslog ${LOG_FILE}

internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${EXTERNAL_INTERFACE}

user.privileged: root
user.unprivileged: ${DAEMON_USER}

clientmethod: none
socksmethod: username

client pass {
    from: ${ALLOW_CIDR} to: 0.0.0.0/0
    log: connect disconnect error
}
EOF

    if ((ALLOW_PRIVATE == 0)); then
        for blocked_network in "${blocked_networks[@]}"; do
            cat <<EOF

socks block {
    from: 0.0.0.0/0 to: ${blocked_network}
    command: connect
    log: connect error
}
EOF
        done
    fi

    cat <<EOF

socks pass {
    from: ${ALLOW_CIDR} to: 0.0.0.0/0
    command: connect
    socksmethod: username
    group: ${AUTH_GROUP}
    log: connect disconnect error
}
EOF
}

render_service_init() {
    cat <<EOF
#!/sbin/openrc-run

name="${APP_NAME}"
description="Managed SOCKS5 proxy node"

command="${DANTE_BIN}"
command_args="-D -p /run/${APP_NAME}/sockd.pid -f ${DANTE_CONFIG_FILE}"
pidfile="/run/${APP_NAME}/sockd.pid"

depend() {
    need net
    after firewall iptables nftables ufw ${APP_NAME}-firewall
}

start_pre() {
    checkpath -d -m 0750 -o root:root /run/${APP_NAME}
    checkpath -d -m 0755 -o root:root "${DANTE_CONFIG_DIR}"
    checkpath -f -m 0644 -o root:root "${LOG_FILE}"
}

extra_started_commands="reload"

reload() {
    ebegin "Reloading \${name}"
    start-stop-daemon --signal HUP --pidfile "\${pidfile}"
    eend \$?
}
EOF
}

nft_input_chains() {
    command -v nft >/dev/null 2>&1 || return 1

    nft -a list ruleset 2>/dev/null | awk '
        $1 == "table" && NF >= 3 {
            family = $2
            table_name = $3
            gsub(/[\{";]/, "", table_name)
        }
        $1 == "chain" && NF >= 2 {
            chain_name = $2
            gsub(/[\{";]/, "", chain_name)
            in_chain = 1
        }
        in_chain && /type[[:space:]]+filter[[:space:]]+hook[[:space:]]+input([[:space:];]|$)/ {
            if ((family == "ip" || family == "inet") && table_name != "" && chain_name != "") {
                print family " " table_name " " chain_name
            }
        }
        in_chain && $1 == "}" {
            in_chain = 0
            chain_name = ""
        }
    ' | sort -u
}

iptables_firewall_is_active() {
    local rules

    command -v iptables >/dev/null 2>&1 || return 1
    rules=$(iptables -S INPUT 2>/dev/null) || return 1
    [[ "$rules" == *$'-P INPUT DROP'* || "$rules" == *$'-A INPUT '* ]]
}

detect_firewall_backend() {
    local nft_chains

    if ((CLI_DISABLE_FIREWALL == 1)); then
        printf '%s\n' "disabled"
        return
    fi

    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        printf '%s\n' "ufw"
        return
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        printf '%s\n' "firewalld"
        return
    fi

    nft_chains=$(nft_input_chains || true)
    if [[ -n "$nft_chains" ]]; then
        printf '%s\n' "nftables"
        return
    fi

    if iptables_firewall_is_active; then
        printf '%s\n' "iptables"
        return
    fi

    printf '%s\n' "none"
}

detect_firewalld_zone() {
    local zone

    zone=$(firewall-cmd --get-zone-of-interface="$EXTERNAL_INTERFACE" 2>/dev/null || true)
    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    fi
    [[ "$zone" =~ ^[A-Za-z0-9_.-]+$ ]] || die "无法确定 firewalld zone。"
    printf '%s\n' "$zone"
}

render_firewall_helper() {
    local quoted_port quoted_cidr quoted_backend quoted_zone quoted_comment

    printf -v quoted_port '%q' "$SOCKS_PORT"
    printf -v quoted_cidr '%q' "$ALLOW_CIDR"
    printf -v quoted_backend '%q' "$FIREWALL_BACKEND"
    printf -v quoted_zone '%q' "$FIREWALL_ZONE"
    printf -v quoted_comment '%q' "socks5-node-${SOCKS_PORT}"

    cat <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail
IFS=\$'\\n\\t'

PORT=${quoted_port}
ALLOW_CIDR=${quoted_cidr}
BACKEND=${quoted_backend}
ZONE=${quoted_zone}
COMMENT=${quoted_comment}
EOF

    cat <<'EOF'

nft_input_chains() {
    nft -a list ruleset 2>/dev/null | awk '
        $1 == "table" && NF >= 3 {
            family = $2
            table_name = $3
            gsub(/[\{";]/, "", table_name)
        }
        $1 == "chain" && NF >= 2 {
            chain_name = $2
            gsub(/[\{";]/, "", chain_name)
            in_chain = 1
        }
        in_chain && /type[[:space:]]+filter[[:space:]]+hook[[:space:]]+input([[:space:];]|$)/ {
            if ((family == "ip" || family == "inet") && table_name != "" && chain_name != "") {
                print family " " table_name " " chain_name
            }
        }
        in_chain && $1 == "}" {
            in_chain = 0
            chain_name = ""
        }
    ' | sort -u
}

ufw_add() {
    local status_output

    command -v ufw >/dev/null 2>&1 || return 1
    status_output=$(LC_ALL=C ufw status 2>/dev/null || true)
    if [[ "$status_output" == *"$COMMENT"* ]]; then
        return
    fi
    ufw allow proto tcp from "$ALLOW_CIDR" to any port "$PORT" comment "$COMMENT"
}

ufw_remove() {
    local status_output added_output line number
    local -a numbers=()

    command -v ufw >/dev/null 2>&1 || return 1
    status_output=$(LC_ALL=C ufw status numbered 2>/dev/null || true)
    while IFS= read -r line; do
        [[ "$line" == *"$COMMENT"* ]] || continue
        number=$line
        number=${number#*\[}
        number=${number%%]*}
        number=${number//[[:space:]]/}
        [[ "$number" =~ ^[0-9]+$ ]] && numbers+=("$number")
    done <<<"$status_output"

    if ((${#numbers[@]} > 0)); then
        mapfile -t numbers < <(printf '%s\n' "${numbers[@]}" | sort -rn)
        for number in "${numbers[@]}"; do
            ufw --force delete "$number" >/dev/null
        done
    else
        ufw --force delete allow proto tcp from "$ALLOW_CIDR" to any port "$PORT" >/dev/null 2>&1 || true
    fi

    added_output=$(LC_ALL=C ufw show added 2>/dev/null || true)
    [[ "$added_output" != *"$COMMENT"* ]]
}

firewalld_rule() {
    printf 'rule family="ipv4" source address="%s" port port="%s" protocol="tcp" accept' \
        "$ALLOW_CIDR" "$PORT"
}

firewalld_add() {
    local rule

    firewall-cmd --state >/dev/null 2>&1 || return 1
    rule=$(firewalld_rule)
    if ! firewall-cmd --permanent --zone="$ZONE" --query-rich-rule="$rule" >/dev/null; then
        firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$rule" >/dev/null
    fi
    if ! firewall-cmd --zone="$ZONE" --query-rich-rule="$rule" >/dev/null; then
        firewall-cmd --zone="$ZONE" --add-rich-rule="$rule" >/dev/null
    fi
}

firewalld_remove() {
    local rule

    firewall-cmd --state >/dev/null 2>&1 || return 1
    rule=$(firewalld_rule)
    if firewall-cmd --permanent --zone="$ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; then
        firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="$rule" >/dev/null
    fi
    if firewall-cmd --zone="$ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; then
        firewall-cmd --zone="$ZONE" --remove-rich-rule="$rule" >/dev/null
    fi
}

iptables_add() {
    local -a rule=(-p tcp -s "$ALLOW_CIDR" --dport "$PORT" -m comment --comment "$COMMENT" -j ACCEPT)

    command -v iptables >/dev/null 2>&1 || return 1
    iptables -w 5 -S INPUT >/dev/null 2>&1 || return 1
    if ! iptables -w 5 -C INPUT "${rule[@]}" >/dev/null 2>&1; then
        iptables -w 5 -I INPUT 1 "${rule[@]}"
    fi
}

iptables_remove() {
    local -a rule=(-p tcp -s "$ALLOW_CIDR" --dport "$PORT" -m comment --comment "$COMMENT" -j ACCEPT)

    command -v iptables >/dev/null 2>&1 || return 1
    iptables -w 5 -S INPUT >/dev/null 2>&1 || return 1
    while iptables -w 5 -C INPUT "${rule[@]}" >/dev/null 2>&1; do
        iptables -w 5 -D INPUT "${rule[@]}"
    done
}

nftables_add() {
    local target family table_name chain_name rules
    local found=0

    command -v nft >/dev/null 2>&1 || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        IFS=' ' read -r family table_name chain_name <<<"$target"
        rules=$(nft -a list chain "$family" "$table_name" "$chain_name" 2>/dev/null || true)
        if [[ "$rules" != *"comment \"$COMMENT\""* ]]; then
            nft insert rule "$family" "$table_name" "$chain_name" \
                ip saddr "$ALLOW_CIDR" tcp dport "$PORT" counter accept comment "$COMMENT"
        fi
        found=1
    done < <(nft_input_chains)

    ((found == 1)) || {
        printf '没有找到 nftables input base chain。\n' >&2
        return 1
    }
}

nftables_remove() {
    local target family table_name chain_name handle
    local rules
    local -a handles=()

    command -v nft >/dev/null 2>&1 || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        IFS=' ' read -r family table_name chain_name <<<"$target"
        rules=$(nft -a list chain "$family" "$table_name" "$chain_name" 2>/dev/null || true)
        mapfile -t handles < <(awk -v marker="$COMMENT" '
            index($0, "comment \"" marker "\"") {
                for (i = 1; i <= NF; i++) {
                    if ($i == "handle" && (i + 1) <= NF) {
                        print $(i + 1)
                    }
                }
            }
        ' <<<"$rules")
        for handle in "${handles[@]}"; do
            [[ "$handle" =~ ^[0-9]+$ ]] || continue
            nft delete rule "$family" "$table_name" "$chain_name" handle "$handle"
        done
    done < <(nft_input_chains)
}

main() {
    local action=${1:-}

    case "$action" in
        add)
            case "$BACKEND" in
                ufw) ufw_add ;;
                firewalld) firewalld_add ;;
                iptables) iptables_add ;;
                nftables) nftables_add ;;
                none | disabled) return 0 ;;
                *) printf '未知防火墙后端：%s\n' "$BACKEND" >&2; return 1 ;;
            esac
            ;;
        remove)
            case "$BACKEND" in
                ufw) ufw_remove ;;
                firewalld) firewalld_remove ;;
                iptables) iptables_remove ;;
                nftables) nftables_remove ;;
                none | disabled) return 0 ;;
                *) printf '未知防火墙后端：%s\n' "$BACKEND" >&2; return 1 ;;
            esac
            ;;
        *)
            printf '用法：%s {add|remove}\n' "$0" >&2
            return 2
            ;;
    esac
}

main "$@"
EOF
}

render_firewall_init() {
    cat <<EOF
#!/sbin/openrc-run

name="${APP_NAME}-firewall"
description="Firewall rule for managed SOCKS5 proxy node"

depend() {
    need net
    after firewall iptables nftables ufw
    before ${APP_NAME}
}

start() {
    ebegin "Applying SOCKS5 firewall rules"
    ${FIREWALL_HELPER} add
    eend \$?
}

stop() {
    ebegin "Removing SOCKS5 firewall rules"
    ${FIREWALL_HELPER} remove
    eend \$?
}
EOF
}

render_state() {
    local key value
    local -a keys=(
        STATE_VERSION SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD PUBLIC_HOST ALLOW_CIDR ALLOW_PRIVATE
        EXTERNAL_INTERFACE DANTE_BIN FIREWALL_BACKEND FIREWALL_ZONE AUTH_GROUP AUTH_GROUP_GID
        AUTH_USER_UID DAEMON_USER DAEMON_USER_UID DAEMON_GROUP DAEMON_GROUP_GID INSTALLED_AT
        DANTE_WAS_PRESENT DANTE_CONFIG_DIR_CREATED SELINUX_ENABLED SELINUX_PORT_MANAGED
    )

    STATE_VERSION=1
    for key in "${keys[@]}"; do
        value=${!key}
        printf '%s=%q\n' "$key" "$value"
    done
}

validate_dante_config() {
    local validation_output

    if ! validation_output=$("$DANTE_BIN" -V -f "$DANTE_CONFIG_FILE" 2>&1); then
        log_error "Dante 配置校验失败："
        printf '%s\n' "$validation_output" >&2
        return 1
    fi
}

discover_public_ipv4() {
    local public_ip=""

    if command -v curl >/dev/null 2>&1; then
        public_ip=$(curl --noproxy '*' -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)
    fi
    if is_valid_ipv4 "$public_ip"; then
        printf '%s\n' "$public_ip"
        return
    fi

    public_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR == 1 { split($4, parts, "/"); print parts[1] }')
    if is_valid_ipv4 "$public_ip"; then
        printf '%s\n' "$public_ip"
    else
        printf '%s\n' "<VPS_PUBLIC_IP>"
    fi
}

smoke_test_proxy() {
    local curl_config proxy_ip

    command -v curl >/dev/null 2>&1 || return 0
    curl_config=$(mktemp /tmp/socks5-node-curl.XXXXXX)
    TEMP_FILES+=("$curl_config")
    chmod 600 "$curl_config"
    cat >"$curl_config" <<EOF
proxy = "socks5h://127.0.0.1:${SOCKS_PORT}"
proxy-user = "${SOCKS_USERNAME}:${SOCKS_PASSWORD}"
url = "https://api.ipify.org"
ipv4
silent
show-error
fail
max-time = 15
EOF

    proxy_ip=$(curl --config "$curl_config" 2>/dev/null || true)
    if is_valid_ipv4 "$proxy_ip"; then
        log_success "SOCKS5 用户名/密码与外网转发测试通过（出口 ${proxy_ip}）。"
    else
        log_warn "服务已监听，但外网转发自检未通过；请检查日志 ${LOG_FILE}。"
    fi
}

socks5_authenticate() {
    local password=$1
    local socket_fd method_response auth_response username_length password_length

    if ! exec {socket_fd}<>"/dev/tcp/127.0.0.1/${SOCKS_PORT}"; then
        return 1
    fi

    printf '\x05\x01\x02' >&"$socket_fd"
    method_response=$(timeout 5 dd bs=1 count=2 <&"$socket_fd" 2>/dev/null \
        | od -An -tx1 | tr -d '[:space:]') || method_response=""
    if [[ "$method_response" != "0502" ]]; then
        exec {socket_fd}>&-
        return 1
    fi

    printf -v username_length '\\%03o' "${#SOCKS_USERNAME}"
    printf -v password_length '\\%03o' "${#password}"
    {
        printf '\x01'
        printf '%b' "$username_length"
        printf '%s' "$SOCKS_USERNAME"
        printf '%b' "$password_length"
        printf '%s' "$password"
    } >&"$socket_fd"

    auth_response=$(timeout 5 dd bs=1 count=2 <&"$socket_fd" 2>/dev/null \
        | od -An -tx1 | tr -d '[:space:]') || auth_response=""
    exec {socket_fd}>&-
    [[ "$auth_response" == "0100" ]]
}

verify_socks5_authentication() {
    local invalid_password="${SOCKS_PASSWORD}0"

    if ! socks5_authenticate "$SOCKS_PASSWORD"; then
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 30 "$LOG_FILE" >&2 || true
        fi
        die "SOCKS5 正确凭据认证失败。"
    fi
    if socks5_authenticate "$invalid_password"; then
        die "SOCKS5 错误密码被接受，拒绝保留不安全的服务。"
    fi
    log_success "SOCKS5 认证握手通过，错误密码已确认被拒绝。"
}

print_runtime_status() {
    local service_status="未运行"
    local display_host dante_version_output dante_version

    if service_is_active "${APP_NAME}"; then
        service_status="运行中"
    fi
    if [[ -n "$PUBLIC_HOST" ]]; then
        display_host=$PUBLIC_HOST
    else
        display_host=$(discover_public_ipv4)
    fi
    dante_version_output=$("$DANTE_BIN" -v 2>&1 || true)
    dante_version=$(sed -n '1p' <<<"$dante_version_output")

    printf '\n%sSOCKS5 节点信息 (Alpine OpenRC)%s\n' "$COLOR_BOLD" "$COLOR_RESET"
    printf '  状态：       %s\n' "$service_status"
    printf '  地址：       %s\n' "$display_host"
    printf '  端口：       %s\n' "$SOCKS_PORT"
    printf '  用户名：     %s\n' "$SOCKS_USERNAME"
    printf '  密码：       %s\n' "$SOCKS_PASSWORD"
    printf '  连接串：     socks5h://%s:%s@%s:%s\n' \
        "$SOCKS_USERNAME" "$SOCKS_PASSWORD" "$display_host" "$SOCKS_PORT"
    printf '  允许来源：   %s\n' "$ALLOW_CIDR"
    printf '  防火墙：     %s%s\n' "$FIREWALL_BACKEND" "${FIREWALL_ZONE:+ (${FIREWALL_ZONE})}"
    printf '  出口网卡：   %s\n' "$EXTERNAL_INTERFACE"
    printf '  Dante：      %s\n' "${dante_version:-未知版本}"
    printf '  安装时间：   %s\n' "${INSTALLED_AT:-未知}"
    printf '\n'
    printf '服务管理：rc-service %s {status|restart|stop}\n' "$APP_NAME"
    printf '查看日志：tail -f %s\n' "$LOG_FILE"
    printf '查看信息：socks5-node info\n'
    printf '卸载节点：socks5-node uninstall\n'
    printf '\n'
    log_warn "标准 SOCKS5 用户名/密码不会加密传输；不要在不可信网络中传递敏感明文数据。"
    log_warn "云厂商安全组不属于 VPS 系统防火墙，如仍无法连接，请手动放行 TCP ${SOCKS_PORT}。"
}

ensure_existing_install_running() {
    local current_auth_gid current_daemon_gid

    [[ -f "$DANTE_CONFIG_FILE" ]] || die "状态文件存在，但 Dante 配置缺失。"
    [[ -x "$FIREWALL_HELPER" ]] || die "状态文件存在，但防火墙辅助脚本缺失。"
    [[ -f "$SERVICE_INIT" && -f "$FIREWALL_INIT" ]] || die "状态文件存在，但 OpenRC init 脚本缺失。"
    [[ -x "$DANTE_BIN" ]] || die "状态文件记录的 Dante 程序不存在：${DANTE_BIN}"

    [[ "$(id -u "$SOCKS_USERNAME" 2>/dev/null || true)" == "$AUTH_USER_UID" ]] \
        || die "托管认证账号 ${SOCKS_USERNAME} 缺失或 UID 已变化。"
    [[ "$(id -u "$DAEMON_USER" 2>/dev/null || true)" == "$DAEMON_USER_UID" ]] \
        || die "托管守护账号 ${DAEMON_USER} 缺失或 UID 已变化。"
    current_auth_gid=$(numeric_group_id "$AUTH_GROUP")
    current_daemon_gid=$(numeric_group_id "$DAEMON_GROUP")
    [[ "$current_auth_gid" == "$AUTH_GROUP_GID" && "$(id -gn "$SOCKS_USERNAME")" == "$AUTH_GROUP" ]] \
        || die "托管认证用户组缺失或 GID 已变化。"
    [[ "$current_daemon_gid" == "$DAEMON_GROUP_GID" && "$(id -gn "$DAEMON_USER")" == "$DAEMON_GROUP" ]] \
        || die "托管守护用户组缺失或 GID 已变化。"

    printf '%s:%s\n' "$SOCKS_USERNAME" "$SOCKS_PASSWORD" | chpasswd
    atomic_write "$DANTE_CONFIG_FILE" 600 render_dante_config
    atomic_write "$FIREWALL_HELPER" 700 render_firewall_helper
    atomic_write "$SERVICE_INIT" 755 render_service_init
    atomic_write "$FIREWALL_INIT" 755 render_firewall_init
    validate_dante_config

    service_enable "${APP_NAME}-firewall"
    service_enable "${APP_NAME}"
    service_restart "${APP_NAME}-firewall"
    service_restart "${APP_NAME}"
    service_is_active "${APP_NAME}" || die "恢复后 SOCKS5 服务仍未运行。"
    if ! wait_for_port_listen "$SOCKS_PORT" 15; then
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 30 "$LOG_FILE" >&2 || true
        fi
        die "恢复后服务在运行，但端口 ${SOCKS_PORT} 没有监听。"
    fi
    verify_socks5_authentication
    smoke_test_proxy
    atomic_write "$STATE_FILE" 600 render_state
    print_runtime_status
}

preflight_new_install() {
    local conflict=""

    if [[ -e "$CONFIG_DIR" ]]; then
        conflict=$CONFIG_DIR
    elif [[ -e "$DANTE_CONFIG_DIR" && ! -d "$DANTE_CONFIG_DIR" ]]; then
        conflict="${DANTE_CONFIG_DIR} 不是目录"
    elif [[ -e "$DANTE_CONFIG_FILE" ]]; then
        conflict=$DANTE_CONFIG_FILE
    elif [[ -e "$FIREWALL_HELPER" ]]; then
        conflict=$FIREWALL_HELPER
    elif [[ -e "$SERVICE_INIT" ]]; then
        conflict=$SERVICE_INIT
    elif [[ -e "$FIREWALL_INIT" ]]; then
        conflict=$FIREWALL_INIT
    fi

    [[ -z "$conflict" ]] || die "发现不受状态文件管理的残留路径：${conflict}。请先人工检查，脚本不会覆盖。"
}

install_cli_helper() {
    local target="/usr/local/bin/${APP_NAME}"
    mkdir -p /usr/local/bin
    if [[ -f "$0" && "$0" != "bash" && "$0" != "/bin/bash" && "$0" != "/usr/bin/bash" && "$0" != "sh" && "$0" != "/bin/sh" ]]; then
        cp -f "$0" "$target" 2>/dev/null && chmod 755 "$target" || true
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REMOTE_SCRIPT_URL" -o "$target" 2>/dev/null && chmod 755 "$target" || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target" "$REMOTE_SCRIPT_URL" 2>/dev/null && chmod 755 "$target" || true
    fi
}

install_action() {
    if [[ -f "$STATE_FILE" ]]; then
        if ((CLI_FORCE == 1)); then
            log_info "检测到已有安装且指定了 --force，正在执行覆盖重装..."
            ASSUME_YES=1 uninstall_action
        elif ((CONFIG_OVERRIDES == 0)); then
            load_state
            log_info "检测到已有安装，正在校验并恢复服务。"
            ensure_existing_install_running
            return
        else
            die "节点已安装。如需使用新参数重新安装，请添加 --force（覆盖重装），或先执行卸载：socks5-node uninstall"
        fi
    fi

    preflight_new_install
    ROLLBACK_ACTIVE=1

    if [[ -n "$CLI_PORT" ]]; then
        is_valid_port "$CLI_PORT" || die "端口必须是 1025-65535 之间的整数。"
        SOCKS_PORT=$((10#$CLI_PORT))
    else
        SOCKS_PORT=$(choose_random_port) || die "无法找到空闲高位端口。"
    fi
    if port_in_use "$SOCKS_PORT"; then
        die "端口 ${SOCKS_PORT} 已被占用。"
    fi

    if [[ -n "$CLI_PASSWORD" ]]; then
        is_valid_password "$CLI_PASSWORD" || die "密码格式无效；请查看 --help。"
        SOCKS_PASSWORD=$CLI_PASSWORD
    else
        SOCKS_PASSWORD=$(random_hex 24)
    fi

    if [[ -n "$CLI_HOST" ]]; then
        is_valid_host "$CLI_HOST" || die "指定的入口地址（IP 或域名）格式无效：${CLI_HOST}"
        PUBLIC_HOST=$CLI_HOST
    else
        PUBLIC_HOST=""
    fi

    if [[ -n "$CLI_ALLOW_CIDR" ]]; then
        ALLOW_CIDR=$(normalize_ipv4_cidr "$CLI_ALLOW_CIDR") || die "无效 IPv4/CIDR：${CLI_ALLOW_CIDR}"
    else
        ALLOW_CIDR="0.0.0.0/0"
    fi
    ALLOW_PRIVATE=$CLI_ALLOW_PRIVATE

    install_dependencies
    if port_in_use "$SOCKS_PORT"; then
        if [[ -z "$CLI_PORT" ]]; then
            SOCKS_PORT=$(choose_random_port) || die "安装依赖后无法重新选择空闲高位端口。"
        else
            die "端口 ${SOCKS_PORT} 在安装依赖期间已被占用。"
        fi
    fi
    EXTERNAL_INTERFACE=$(detect_external_interface)
    log_info "IPv4 出口网卡：${EXTERNAL_INTERFACE}"

    generate_managed_identities
    create_managed_accounts

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    if [[ ! -d "$DANTE_CONFIG_DIR" ]]; then
        mkdir -p "$DANTE_CONFIG_DIR"
        chmod 755 "$DANTE_CONFIG_DIR"
        DANTE_CONFIG_DIR_CREATED=1
    fi
    mkdir -p "$(dirname -- "$FIREWALL_HELPER")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    FIREWALL_BACKEND=$(detect_firewall_backend)
    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        FIREWALL_ZONE=$(detect_firewalld_zone)
    fi

    atomic_write "$DANTE_CONFIG_FILE" 600 render_dante_config
    atomic_write "$FIREWALL_HELPER" 700 render_firewall_helper
    atomic_write "$SERVICE_INIT" 755 render_service_init
    atomic_write "$FIREWALL_INIT" 755 render_firewall_init

    log_info "正在校验 Dante 配置。"
    validate_dante_config

    log_info "正在应用防火墙规则（${FIREWALL_BACKEND}${FIREWALL_ZONE:+/${FIREWALL_ZONE}}）。"
    service_enable "${APP_NAME}-firewall"
    service_enable "${APP_NAME}"
    service_restart "${APP_NAME}-firewall"
    service_restart "${APP_NAME}"

    service_is_active "${APP_NAME}" || {
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 30 "$LOG_FILE" >&2 || true
        fi
        die "SOCKS5 服务启动失败。"
    }

    if ! wait_for_port_listen "$SOCKS_PORT" 15; then
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 30 "$LOG_FILE" >&2 || true
        fi
        die "服务已启动，但端口 ${SOCKS_PORT} 没有监听。"
    fi

    verify_socks5_authentication
    smoke_test_proxy

    INSTALLED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    atomic_write "$STATE_FILE" 600 render_state
    install_cli_helper
    ROLLBACK_ACTIVE=0

    log_success "SOCKS5 节点安装完成。"
    print_runtime_status
}

info_action() {
    load_state
    print_runtime_status
}

numeric_group_id() {
    local group_name=$1
    getent group "$group_name" 2>/dev/null | awk -F: '{print $3}'
}

remove_managed_user() {
    local username=$1
    local expected_uid=${2:-}
    local current_uid

    if ! id "$username" >/dev/null 2>&1; then
        return
    fi
    current_uid=$(id -u "$username")
    if [[ -z "$expected_uid" || "$current_uid" == "$expected_uid" ]]; then
        if command -v userdel >/dev/null 2>&1; then
            userdel "$username" 2>/dev/null || true
        elif command -v deluser >/dev/null 2>&1; then
            deluser "$username" 2>/dev/null || true
        fi
    else
        log_warn "账号 ${username} 的 UID 已变化，未自动删除。"
    fi
}

remove_managed_group() {
    local group_name=$1
    local expected_gid=${2:-}
    local current_gid

    if ! getent group "$group_name" >/dev/null 2>&1; then
        return
    fi
    current_gid=$(numeric_group_id "$group_name")
    if [[ -z "$expected_gid" || "$current_gid" == "$expected_gid" ]]; then
        if command -v groupdel >/dev/null 2>&1; then
            groupdel "$group_name" 2>/dev/null || true
        elif command -v delgroup >/dev/null 2>&1; then
            delgroup "$group_name" 2>/dev/null || true
        fi
    else
        log_warn "用户组 ${group_name} 的 GID 已变化，未自动删除。"
    fi
}

confirm_uninstall() {
    local reply

    ((ASSUME_YES == 1)) && return 0
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        die "非交互环境卸载请显式添加 --yes。"
    fi

    printf '将停止并删除 socks5-node 服务、规则、凭据和托管账号。继续？[y/N] '
    if [[ -e /dev/tty ]]; then
        IFS= read -r reply </dev/tty || true
    else
        IFS= read -r reply || true
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

uninstall_action() {
    local cleanup_failed=0

    if [[ ! -f "$STATE_FILE" ]]; then
        log_info "没有检测到已完成的 socks5-node 安装。"
        return
    fi

    load_state
    if ! confirm_uninstall; then
        log_info "已取消卸载。"
        return
    fi

    service_stop "${APP_NAME}"
    service_stop "${APP_NAME}-firewall"
    service_disable "${APP_NAME}"
    service_disable "${APP_NAME}-firewall"

    if [[ -x "$FIREWALL_HELPER" ]]; then
        if ! "$FIREWALL_HELPER" remove; then
            log_warn "防火墙规则自动清理失败，请检查端口 ${SOCKS_PORT}。"
            cleanup_failed=1
        fi
    fi
    ((cleanup_failed == 0)) || die "卸载已暂停，状态文件与辅助脚本仍保留；修复上述问题后可重试。"

    rm -f -- "$SERVICE_INIT" "$FIREWALL_INIT" "$FIREWALL_HELPER" "$DANTE_CONFIG_FILE" "$LOG_FILE" "/usr/local/bin/${APP_NAME}"

    remove_managed_user "$SOCKS_USERNAME" "$AUTH_USER_UID"
    remove_managed_user "$DAEMON_USER" "$DAEMON_USER_UID"
    remove_managed_group "$AUTH_GROUP" "$AUTH_GROUP_GID"
    remove_managed_group "$DAEMON_GROUP" "$DAEMON_GROUP_GID"

    if [[ "$CONFIG_DIR" == "/etc/socks5-node" ]]; then
        rm -rf -- "$CONFIG_DIR"
    else
        die "拒绝删除异常配置目录：${CONFIG_DIR}"
    fi
    if ((DANTE_CONFIG_DIR_CREATED == 1)) && [[ "$DANTE_CONFIG_DIR" == "/etc/socks" ]]; then
        rmdir -- "$DANTE_CONFIG_DIR" >/dev/null 2>&1 || true
    fi

    log_success "socks5-node 已卸载；发行版的 Dante 软件包被保留。"
}

main() {
    parse_args "$@"
    require_root_and_openrc
    acquire_lock

    case "$ACTION" in
        install) install_action ;;
        info) info_action ;;
        uninstall) uninstall_action ;;
        *) die "未知动作：${ACTION}" ;;
    esac
}

if [[ "${SOCKS5_NODE_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
