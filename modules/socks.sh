#!/usr/bin/env bash
# Wrapper around the already-adapted Alpine Dante SOCKS5 installer.

if [[ -z "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

socks_script_path() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    printf '%s\n' "${root}/modules/socks5_alpine.sh"
}

socks_usage() {
    cat <<'EOF'
Alpine SOCKS5（Dante / OpenRC）

用法：
  alpine.sh socks                     交互菜单（停留在子菜单）
  alpine.sh socks install [选项]      安装 SOCKS5
  alpine.sh socks nat                 交互式 NAT 模式（指定端口与入口）
  alpine.sh socks info                查看节点信息与连接串
  alpine.sh socks restart             重启 SOCKS5 服务
  alpine.sh socks status              查看服务状态
  alpine.sh socks uninstall [--yes]   卸载 SOCKS5 节点

安装选项：
  -p, --port PORT          指定监听端口（NAT 请填已映射的端口）
  -H, --host HOST          指定连接入口地址（IPv4 或域名，用于 NAT VPS）
  -u, --username USER      指定认证用户名（留空随机）
  -P, --password PASS      指定认证密码（留空随机）
      --allow-cidr CIDR    允许连接的 IP 网段（默认 0.0.0.0/0）
      --allow-private      允许代理访问内网地址
      --no-firewall        不修改防火墙
  -f, --force              覆盖已有安装
  -y, --yes                跳过卸载确认
EOF
}

prompt_socks_nat() {
    local port host user pass
    echo
    title "NAT 模式安装（指定端口与入口地址）"
    dim "适合只有少量映射端口的 NAT VPS / 容器。"

    ask port "监听端口（NAT 请填已映射的端口，如 10240）: "
    [[ -n "$port" ]] || { warn "必须指定监听端口。"; return 1; }
    is_valid_port "$port" || { warn "端口无效：${port}（范围 1025-65535）"; return 1; }

    ask host "连接入口地址（NAT 公网 IP 或 DDNS 域名，留空自动检测）: "
    if [[ -n "$host" ]]; then
        is_valid_host "$host" || { warn "地址格式无效：${host}"; return 1; }
    fi

    ask user "认证用户名（留空随机生成）: "
    if [[ -n "$user" ]]; then
        [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { warn "用户名格式无效（以小写字母开头，1-30位）"; return 1; }
    fi

    ask pass "认证密码（留空随机生成，最少 12 位）: "
    if [[ -n "$pass" ]]; then
        [[ "$pass" =~ ^[A-Za-z0-9._-]{12,128}$ ]] || { warn "密码格式无效（12-128位英文字母/数字/._-）"; return 1; }
    fi

    local -a args=(install -p "$port")
    [[ -n "$host" ]] && args+=(-H "$host")
    [[ -n "$user" ]] && args+=(-u "$user")
    [[ -n "$pass" ]] && args+=(-P "$pass")
    if [[ -f "/etc/socks5-node/state.env" ]]; then
        if confirm "检测到已有 SOCKS5 安装，是否覆盖重装？" "y"; then
            args+=(-f)
        else
            info "已取消安装。"
            return 0
        fi
    fi

    local script
    script="$(socks_script_path)"
    bash "$script" "${args[@]}"
}

socks_menu() {
    local script
    script="$(socks_script_path)"
    while true; do
        echo
        printf '%sAlpine SOCKS5 (Dante / OpenRC)%s\n' "$C_BLUE" "$C_RESET"
        dim "高性能 Dante SOCKS5 代理 · 账号隔离 · 防火墙放行"
        echo "────────────────────────────────────────"
        echo "  1) 一键随机安装（标准 VPS，随机端口）"
        echo "  2) NAT 模式安装（指定端口 / 入口地址）"
        echo "  3) 查看节点信息 / 连接串"
        echo "  4) 重启 SOCKS5 服务"
        echo "  5) 卸载 SOCKS5 节点"
        echo "  0) 返回主菜单"
        echo "────────────────────────────────────────"
        local choice
        ask choice "请选择: "
        case "$choice" in
            1)
                if [[ -f "/etc/socks5-node/state.env" ]]; then
                    if confirm "检测到已有安装，是否覆盖重装？" "n"; then
                        bash "$script" install -f
                    else
                        bash "$script" info
                    fi
                else
                    bash "$script" install
                fi
                pause
                ;;
            2)
                prompt_socks_nat || true
                pause
                ;;
            3)
                if [[ -f "/etc/socks5-node/state.env" ]]; then
                    bash "$script" info
                else
                    warn "尚未安装 SOCKS5 节点。"
                fi
                pause
                ;;
            4)
                require_root
                if [[ -f "/etc/socks5-node/state.env" ]]; then
                    service_restart socks5-node || warn "重启失败。"
                    ok "SOCKS5 服务已重启。"
                else
                    warn "尚未安装 SOCKS5 节点。"
                fi
                pause
                ;;
            5)
                require_root
                if [[ -f "/etc/socks5-node/state.env" ]]; then
                    bash "$script" uninstall
                else
                    warn "尚未安装 SOCKS5 节点。"
                fi
                pause
                ;;
            0|q|Q) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

socks_main() {
    local script
    script="$(socks_script_path)"
    [[ -f "$script" ]] || die "找不到 Alpine SOCKS5 脚本：${script}"

    local command="${1:-menu}"
    (($# == 0)) || shift
    case "$command" in
        menu) socks_menu "$@" ;;
        nat) prompt_socks_nat "$@" ;;
        install) bash "$script" install "$@" ;;
        info|links) bash "$script" info "$@" ;;
        status)
            if service_is_active socks5-node; then
                ok "SOCKS5 服务运行中。"
                bash "$script" info "$@"
            else
                warn "SOCKS5 服务未运行。"
            fi
            ;;
        restart)
            require_root
            service_restart socks5-node || die "重启失败。"
            ok "已重启 socks5-node"
            ;;
        uninstall) bash "$script" uninstall "$@" ;;
        help|-h|--help) socks_usage ;;
        *)
            # Forward any flag-style args directly to socks5_alpine.sh
            bash "$script" "$command" "$@"
            ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    socks_main "$@"
fi
