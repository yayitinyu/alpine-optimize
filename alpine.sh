#!/usr/bin/env bash
# Alpine Optimize — aggregated VPS toolkit (OpenRC / apk / musl)

# If executed via /bin/sh on Alpine, re-exec with bash.
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "正在通过 apk 安装 bash..." >&2
            apk add --no-cache bash >/dev/null 2>&1 || {
                echo "错误：无法自动安装 bash，请先手动执行 apk add bash" >&2
                exit 1
            }
        else
            echo "错误：运行此脚本需要 bash。" >&2
            exit 1
        fi
    fi
    if [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "请使用：apk add curl bash && curl -fsSL https://raw.githubusercontent.com/yayitinyu/alpine-optimize/main/alpine.sh | bash" >&2
    exit 1
fi

set -Eeuo pipefail

: "${ALPINE_OPTIMIZE_REPO:=yayitinyu/alpine-optimize}"
: "${ALPINE_OPTIMIZE_BRANCH:=main}"
: "${ALPINE_OPTIMIZE_HOME:=/opt/alpine-optimize}"

SCRIPT_VERSION="1.0.0"

is_complete_tree() {
    local dir=$1
    [[ -f "${dir}/lib/common.sh" \
        && -f "${dir}/modules/optimize.sh" \
        && -f "${dir}/modules/realm.sh" \
        && -f "${dir}/modules/sing-box.sh" \
        && -f "${dir}/modules/socks.sh" \
        && -f "${dir}/modules/socks5_alpine.sh" ]]
}

resolve_root_dir() {
    local src="${BASH_SOURCE[0]:-}"
    local dir=""

    if [[ -n "$src" && -f "$src" ]]; then
        case "$src" in
            /dev/fd/* | /proc/self/fd/*) ;;
            *)
                dir="$(cd "$(dirname "$src")" && pwd)"
                if is_complete_tree "$dir"; then
                    printf '%s\n' "$dir"
                    return 0
                fi
                ;;
        esac
    fi
    return 1
}

bootstrap_repo() {
    local dest="$ALPINE_OPTIMIZE_HOME"
    local repo_url="https://github.com/${ALPINE_OPTIMIZE_REPO}.git"
    local tarball="https://github.com/${ALPINE_OPTIMIZE_REPO}/archive/refs/heads/${ALPINE_OPTIMIZE_BRANCH}.tar.gz"
    local tmp extracted

    if [[ "${EUID}" -ne 0 ]]; then
        dest="${TMPDIR:-/tmp}/alpine-optimize"
    fi

    echo "正在获取 Alpine Optimize（${ALPINE_OPTIMIZE_REPO}@${ALPINE_OPTIMIZE_BRANCH}）..." >&2
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache git curl tar ca-certificates >/dev/null
    fi
    command -v curl >/dev/null 2>&1 || {
        echo "错误：需要 curl 才能远程安装。" >&2
        exit 1
    }

    if command -v git >/dev/null 2>&1; then
        if [[ -d "${dest}/.git" ]]; then
            git -C "$dest" fetch --depth 1 origin "$ALPINE_OPTIMIZE_BRANCH" 2>/dev/null \
                && git -C "$dest" reset --hard "origin/${ALPINE_OPTIMIZE_BRANCH}" 2>/dev/null \
                && git -C "$dest" clean -fd 2>/dev/null \
                || {
                    rm -rf "$dest"
                    git clone --depth 1 --branch "$ALPINE_OPTIMIZE_BRANCH" "$repo_url" "$dest"
                }
        else
            rm -rf "$dest"
            git clone --depth 1 --branch "$ALPINE_OPTIMIZE_BRANCH" "$repo_url" "$dest"
        fi
    else
        tmp="$(mktemp -d)"
        curl -fsSL --retry 3 --connect-timeout 15 -o "${tmp}/src.tar.gz" "$tarball" \
            || { echo "错误：无法下载仓库压缩包。" >&2; rm -rf "$tmp"; exit 1; }
        tar -xzf "${tmp}/src.tar.gz" -C "$tmp"
        extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        [[ -n "$extracted" ]] || { echo "错误：压缩包内容无效。" >&2; rm -rf "$tmp"; exit 1; }
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        mv "$extracted" "$dest"
        rm -rf "$tmp"
    fi

    is_complete_tree "$dest" || {
        echo "错误：下载后仍缺少脚本文件。" >&2
        exit 1
    }
    # Re-attach stdin to the terminal so the menu can accept keypresses after curl|bash.
    if [[ -e /dev/tty ]]; then
        exec bash "${dest}/alpine.sh" "$@" </dev/tty
    else
        exec bash "${dest}/alpine.sh" "$@"
    fi
}

ROOT_DIR="$(resolve_root_dir || true)"
if [[ -z "${ROOT_DIR}" ]]; then
    bootstrap_repo "$@"
fi

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

usage() {
    cat <<EOF
${PROJECT_NAME} v${SCRIPT_VERSION}

面向 Alpine Linux（OpenRC / apk / musl）的聚合工具：系统优化、Realm 转发、
SOCKS5 节点、精简 sing-box。

远程一键:
  apk add --no-cache curl bash
  curl -fsSL https://raw.githubusercontent.com/${ALPINE_OPTIMIZE_REPO}/${ALPINE_OPTIMIZE_BRANCH}/alpine.sh | bash
  curl -fsSL https://raw.githubusercontent.com/${ALPINE_OPTIMIZE_REPO}/${ALPINE_OPTIMIZE_BRANCH}/alpine.sh | bash -s -- --all -y

用法:
  bash alpine.sh                         交互菜单
  bash alpine.sh optimize [选项]         系统优化
  bash alpine.sh realm <命令>            端口转发
  bash alpine.sh socks [选项]            Dante SOCKS5
  bash alpine.sh sing-box <命令>         精简 sing-box
  bash alpine.sh tools                   安装运维工具
  bash alpine.sh bootstrap               community 源 + GNU 工具
  bash alpine.sh ssh-key                 SSH 密钥
  bash alpine.sh status                  系统优化状态
  bash alpine.sh self-update             更新本仓库脚本
  bash alpine.sh uninstall               卸载优化配置

快捷:
  bash alpine.sh --all [-y] [--bandwidth N] [--region asia|overseas]
  bash alpine.sh --status
  bash alpine.sh --help

各子命令帮助:
  bash alpine.sh optimize --help
  bash alpine.sh realm --help
  bash alpine.sh socks --help
  bash alpine.sh sing-box --help
EOF
}

self_update() {
    local tmp extracted tarball
    require_root
    info "更新 ${ALPINE_OPTIMIZE_REPO}@${ALPINE_OPTIMIZE_BRANCH} ..."
    if [[ -d "${ROOT_DIR}/.git" ]] && command_exists git; then
        git -C "$ROOT_DIR" fetch --depth 1 origin "$ALPINE_OPTIMIZE_BRANCH" \
            && git -C "$ROOT_DIR" reset --hard "origin/${ALPINE_OPTIMIZE_BRANCH}" \
            && git -C "$ROOT_DIR" clean -fd \
            || die "git 更新失败。"
        ok "脚本已更新：${ROOT_DIR}"
        return 0
    fi

    tarball="https://github.com/${ALPINE_OPTIMIZE_REPO}/archive/refs/heads/${ALPINE_OPTIMIZE_BRANCH}.tar.gz"
    command_exists curl || die "需要 curl 才能更新。"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 --connect-timeout 15 -o "${tmp}/src.tar.gz" "$tarball" \
        || { rm -rf "$tmp"; die "无法下载更新包。"; }
    tar -xzf "${tmp}/src.tar.gz" -C "$tmp"
    extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$extracted" ]] || { rm -rf "$tmp"; die "更新包内容无效。"; }
    cp -a "${extracted}/." "${ROOT_DIR}/"
    rm -rf "$tmp"
    is_complete_tree "$ROOT_DIR" || die "更新后文件不完整。"
    ok "脚本已更新：${ROOT_DIR}"
}

toolkit_status() {
    do_status
    echo
    title "=== 已安装服务 ==="
    if [[ -x /usr/local/bin/realm || -f /etc/init.d/realm ]]; then
        if service_is_active realm; then
            ok "Realm: 运行中"
        else
            warn "Realm: 已安装但未运行"
        fi
    else
        dim "Realm: 未安装"
    fi
    if [[ -f /etc/init.d/socks5-node ]]; then
        if service_is_active socks5-node; then
            ok "SOCKS5: 运行中"
        else
            warn "SOCKS5: 已安装但未运行"
        fi
    else
        dim "SOCKS5: 未安装"
    fi
    if [[ -f /etc/init.d/alpine-sing-box ]]; then
        if service_is_active alpine-sing-box; then
            ok "sing-box: 运行中"
        else
            warn "sing-box: 已安装但未运行"
        fi
    else
        dim "sing-box: 未安装"
    fi
}

show_main_menu() {
    clear 2>/dev/null || true
    printf '%s%s%s\n' "$C_BOLD" "Alpine Optimize  v${SCRIPT_VERSION}" "$C_RESET"
    dim "官方 BBR · OpenRC 服务 · musl 二进制 · 精简代理"
    echo "  系统: ${OS_NAME:-Linux} | 内存: ${MEM_MB:-?}MB | 虚拟化: ${VIRT_KIND:-unknown}"
    echo "  网卡: ${PRIMARY_IFACE:-unknown} | 拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
    echo
    echo "────────────────────────────────────────"
    echo "  0) 一键系统优化"
    echo "  1) 系统优化（分项菜单）"
    echo "  2) Realm 端口转发"
    echo "  3) SOCKS5 节点（Dante）"
    echo "  4) sing-box（VLESS / AnyTLS / WARP）"
    echo "  5) SSH 密钥登录"
    echo "  6) 查看优化状态"
    echo "  7) 卸载优化配置"
    echo "  q) 退出"
    echo "────────────────────────────────────────"
}

main_menu() {
    require_root
    require_alpine
    detect_system
    while true; do
        show_main_menu
        local choice
        ask choice "请选择: "
        case "$choice" in
            0) do_all; pause ;;
            1) optimize_menu ;;
            2) realm_menu ;;
            3) socks_main ;;
            4) singbox_menu ;;
            5) do_ssh_key; pause ;;
            6) toolkit_status; pause ;;
            7) do_uninstall; pause ;;
            q|Q|exit) echo "再见。"; exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

dispatch() {
    if [[ $# -eq 0 ]]; then
        main_menu
        return
    fi

    case "$1" in
        -h|--help|help) usage; return 0 ;;
        --version) printf '%s %s\n' "$PROJECT_NAME" "$SCRIPT_VERSION"; return 0 ;;
        --all)
            shift
            require_root
            require_alpine
            detect_system
            optimize_parse_and_run --all "$@"
            return
            ;;
        --status|status)
            require_root
            require_alpine
            detect_system
            toolkit_status
            return
            ;;
        --uninstall|uninstall)
            require_root
            require_alpine
            detect_system
            do_uninstall
            return
            ;;
        optimize|opt)
            shift
            optimize_main "$@"
            ;;
        realm)
            shift
            realm_main "$@"
            ;;
        socks|socks5)
            shift
            socks_main "$@"
            ;;
        sing-box|singbox|sb)
            shift
            singbox_main "$@"
            ;;
        tools)
            require_root
            require_alpine
            detect_system
            do_install_tools
            ;;
        bootstrap)
            require_root
            require_alpine
            detect_system
            do_bootstrap
            ;;
        ssh-key|ssh)
            require_root
            require_alpine
            detect_system
            do_ssh_key
            ;;
        time)
            require_root
            require_alpine
            detect_system
            do_time_sync
            ;;
        self-update|update-script)
            self_update "$@"
            ;;
        *)
            err "未知命令：$1"
            usage
            return 1
            ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    dispatch "$@"
fi
