#!/usr/bin/env bash
# Alpine VPS optimize: official BBR, sysctl, limits, SWAP, disk, tools, cron.
# Adapted from nanami-vps-optimize for OpenRC / apk / musl.

if [[ -z "${ALPINE_OPTIMIZE_COMMON:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

OPTIMIZE_VERSION="1.0.0"
SYSCTL_FILE="/etc/sysctl.d/99-alpine-optimize.conf"
LIMITS_FILE="/etc/security/limits.d/99-alpine-optimize.conf"
MODULES_LOAD_FILE="/etc/modules-load.d/alpine-optimize-bbr.conf"
BOOT_APPLY_BIN="/usr/local/sbin/alpine-optimize-boot"
BOOT_APPLY_LOCAL="/etc/local.d/alpine-optimize-boot.start"
CLEAN_SCRIPT="/etc/periodic/daily/alpine-optimize-clean"
LOG_DIR="/var/log/alpine-optimize"
STATE_DIR="/etc/alpine-optimize"
STATE_FILE="${STATE_DIR}/state.env"
RC_CONF="/etc/rc.conf"
RC_BEGIN="# BEGIN alpine-optimize"
RC_END="# END alpine-optimize"
SSH_PUBKEY_DROPIN="/etc/ssh/sshd_config.d/99-alpine-optimize-pubkey.conf"
SSH_KEYONLY_DROPIN="/etc/ssh/sshd_config.d/99-alpine-optimize-keyonly.conf"

ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
REGION="${REGION:-asia}"
BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-}"
TIMEZONE="${TIMEZONE:-}"
NEED_REBOOT=0

ensure_opt_dirs() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 700 "$LOG_DIR" 2>/dev/null || true
}

opt_log() {
    local level="$1"; shift
    ensure_opt_dirs
    printf '%s [%s] %s\n' "$(iso_now)" "$level" "$*" >>"${LOG_DIR}/run.log" 2>/dev/null || true
}

save_state() {
    ensure_opt_dirs
    write_file "$STATE_FILE" 0644 <<EOF
# Alpine optimize state - do not edit manually
VERSION=${OPTIMIZE_VERSION}
APPLIED_AT=$(iso_now)
REGION=${REGION}
BANDWIDTH_MBPS=${BANDWIDTH_MBPS:-}
PRIMARY_IFACE=${PRIMARY_IFACE:-}
TIMEZONE=${TIMEZONE:-}
EOF
}

# BDP-aware TCP buffer in MB. Uses global MEM_MB.
calculate_buffer_mb() {
    local bandwidth="${1:-1000}"
    local region="${2:-asia}"
    local buffer_mb mem_cap

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [[ "$bandwidth" -le 0 ]]; then
        bandwidth=1000
    fi

    if [[ "$region" == "overseas" ]]; then
        if   (( bandwidth <= 100 ));  then buffer_mb=8
        elif (( bandwidth <= 200 ));  then buffer_mb=16
        elif (( bandwidth <= 300 ));  then buffer_mb=20
        elif (( bandwidth <= 500 ));  then buffer_mb=32
        elif (( bandwidth <= 700 ));  then buffer_mb=48
        else buffer_mb=64
        fi
    else
        if   (( bandwidth <= 100 ));  then buffer_mb=6
        elif (( bandwidth <= 200 ));  then buffer_mb=8
        elif (( bandwidth <= 300 ));  then buffer_mb=10
        elif (( bandwidth <= 500 ));  then buffer_mb=12
        elif (( bandwidth <= 700 ));  then buffer_mb=14
        elif (( bandwidth <= 1000 )); then buffer_mb=16
        elif (( bandwidth <= 1500 )); then buffer_mb=20
        elif (( bandwidth <= 2000 )); then buffer_mb=24
        elif (( bandwidth <= 5000 )); then buffer_mb=28
        else buffer_mb=32
        fi
    fi

    mem_cap=$(( MEM_MB / 8 ))
    (( mem_cap < 4 )) && mem_cap=4
    if (( buffer_mb > mem_cap )); then
        buffer_mb=$mem_cap
    fi
    printf '%s' "$buffer_mb"
}

compute_memory_params() {
    RMEM_DEFAULT=262144
    WMEM_DEFAULT=262144
    SWAPPINESS=10
    NOTSENT_LOWAT=16384

    if (( MEM_MB <= 256 )); then
        SOMAXCONN=4096
        SYN_BACKLOG=2048
        NETDEV_BACKLOG=2000
        FILE_MAX=524288
        DIRTY_BG=4194304
        DIRTY_BYTES=16777216
        SWAPPINESS=20
        MIN_FREE_KB=8192
        CONNTRACK_MAX=65536
    elif (( MEM_MB <= 512 )); then
        SOMAXCONN=8192
        SYN_BACKLOG=4096
        NETDEV_BACKLOG=4096
        FILE_MAX=1048576
        DIRTY_BG=8388608
        DIRTY_BYTES=33554432
        SWAPPINESS=15
        MIN_FREE_KB=16384
        CONNTRACK_MAX=131072
    elif (( MEM_MB <= 1024 )); then
        SOMAXCONN=16384
        SYN_BACKLOG=8192
        NETDEV_BACKLOG=8192
        FILE_MAX=1048576
        DIRTY_BG=16777216
        DIRTY_BYTES=67108864
        SWAPPINESS=10
        MIN_FREE_KB=32768
        CONNTRACK_MAX=262144
    elif (( MEM_MB <= 2048 )); then
        SOMAXCONN=32768
        SYN_BACKLOG=16384
        NETDEV_BACKLOG=16384
        FILE_MAX=2097152
        DIRTY_BG=33554432
        DIRTY_BYTES=134217728
        SWAPPINESS=10
        MIN_FREE_KB=65536
        CONNTRACK_MAX=524288
    else
        SOMAXCONN=65535
        SYN_BACKLOG=32768
        NETDEV_BACKLOG=32768
        FILE_MAX=2097152
        DIRTY_BG=67108864
        DIRTY_BYTES=268435456
        SWAPPINESS=5
        MIN_FREE_KB=65536
        CONNTRACK_MAX=1048576
    fi
}

prompt_bandwidth_and_region() {
    if [[ -n "$BANDWIDTH_MBPS" && "$NONINTERACTIVE" -eq 1 ]]; then
        return 0
    fi
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-1000}"
        REGION="${REGION:-asia}"
        return 0
    fi

    title "=== 带宽与服务地区 ==="
    echo "缓冲区按 BDP（带宽 × 延迟）估算，地区决定 RTT 假设。"
    echo
    echo "1) 手动选择常用档位（推荐）"
    echo "2) 输入自定义带宽 (Mbps)"
    echo "3) 使用默认 1000 Mbps"
    echo
    local choice tier custom rchoice buf
    ask choice "请选择 [1]: "
    choice="${choice:-1}"
    case "$choice" in
        1)
            echo
            echo "  a) 100 Mbps   b) 200 Mbps   c) 300 Mbps"
            echo "  d) 500 Mbps   e) 700 Mbps   f) 1 Gbps (推荐)"
            echo "  g) 1.5 Gbps   h) 2 Gbps     i) 2.5 Gbps"
            ask tier "请选择档位 [f]: "
            tier="${tier:-f}"
            case "$tier" in
                a) BANDWIDTH_MBPS=100 ;;
                b) BANDWIDTH_MBPS=200 ;;
                c) BANDWIDTH_MBPS=300 ;;
                d) BANDWIDTH_MBPS=500 ;;
                e) BANDWIDTH_MBPS=700 ;;
                g) BANDWIDTH_MBPS=1500 ;;
                h) BANDWIDTH_MBPS=2000 ;;
                i) BANDWIDTH_MBPS=2500 ;;
                *) BANDWIDTH_MBPS=1000 ;;
            esac
            ;;
        2)
            while true; do
                ask custom "请输入上传带宽 (Mbps): "
                if [[ "$custom" =~ ^[0-9]+$ ]] && (( custom > 0 && custom <= 100000 )); then
                    BANDWIDTH_MBPS="$custom"
                    break
                fi
                warn "请输入 1-100000 之间的整数。"
            done
            ;;
        *)
            BANDWIDTH_MBPS=1000
            ;;
    esac

    echo
    echo "服务器主要服务的客户端地区："
    echo "1) 亚太（港/日/新/韩等，RTT 较低）推荐"
    echo "2) 美国/欧洲（跨洋高延迟，更大缓冲区）"
    ask rchoice "请选择 [1]: "
    rchoice="${rchoice:-1}"
    case "$rchoice" in
        2) REGION="overseas" ;;
        *) REGION="asia" ;;
    esac

    buf="$(calculate_buffer_mb "$BANDWIDTH_MBPS" "$REGION")"
    echo
    ok "带宽: ${BANDWIDTH_MBPS} Mbps | 地区: ${REGION} | 推荐 TCP 缓冲: ${buf} MB"
}

clean_sysctl_conflicts() {
    [[ -f /etc/sysctl.conf ]] || return 0
    backup_if_exists /etc/sysctl.conf
    sed -i \
        -e '/^net\.core\.rmem_max/s/^/# /' \
        -e '/^net\.core\.wmem_max/s/^/# /' \
        -e '/^net\.core\.rmem_default/s/^/# /' \
        -e '/^net\.core\.wmem_default/s/^/# /' \
        -e '/^net\.core\.default_qdisc/s/^/# /' \
        -e '/^net\.core\.somaxconn/s/^/# /' \
        -e '/^net\.core\.netdev_max_backlog/s/^/# /' \
        -e '/^net\.ipv4\.tcp_rmem/s/^/# /' \
        -e '/^net\.ipv4\.tcp_wmem/s/^/# /' \
        -e '/^net\.ipv4\.tcp_congestion_control/s/^/# /' \
        -e '/^net\.ipv4\.tcp_fastopen/s/^/# /' \
        -e '/^net\.ipv4\.tcp_notsent_lowat/s/^/# /' \
        -e '/^net\.ipv4\.tcp_slow_start_after_idle/s/^/# /' \
        -e '/^net\.ipv4\.tcp_mtu_probing/s/^/# /' \
        /etc/sysctl.conf 2>/dev/null || true
}

append_modules_line() {
    local module="$1"
    local modules_file="/etc/modules"
    [[ -f "$modules_file" ]] || : >"$modules_file"
    if ! grep -qx "$module" "$modules_file" 2>/dev/null; then
        printf '%s\n' "$module" >>"$modules_file"
    fi
}

bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        || sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

enable_bbr_module() {
    if is_container; then
        warn "容器环境通常不能加载内核模块，仅尝试写入 sysctl。"
    else
        command_exists modprobe || ensure_packages kmod || true
        modprobe tcp_bbr 2>/dev/null || true
        modprobe sch_fq 2>/dev/null || true
        append_modules_line tcp_bbr
        mkdir -p "$(dirname "$MODULES_LOAD_FILE")"
        write_file "$MODULES_LOAD_FILE" 0644 <<'EOF'
# Load official BBR congestion control at boot (Alpine Optimize)
tcp_bbr
EOF
    fi

    if ! bbr_available; then
        err "当前内核未提供官方 BBR（tcp_bbr）。"
        err "Alpine 云主机请优先使用 linux-virt（5.x/6.x），然后 reboot。"
        err "例如：apk add linux-virt && reboot"
        return 1
    fi
    return 0
}

apply_tc_fq() {
    local dev name
    command_exists tc || ensure_packages iproute2 || true
    command_exists tc || return 0
    for dev in /sys/class/net/*; do
        [[ -e "$dev" ]] || continue
        name="$(basename "$dev")"
        case "$name" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*|cni*|flannel*|cali*) continue ;;
        esac
        tc qdisc replace dev "$name" root fq 2>/dev/null || true
    done
}

apply_mss_clamp() {
    local tag="alpine-optimize-mss"
    if command_exists iptables; then
        while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null; do
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || break
        done
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
        while iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null; do
            iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || break
        done
        iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
    fi
}

apply_initcwnd() {
    local route clean
    command_exists ip || return 0
    route="$(ip -o -4 route show to default 2>/dev/null | head -n1 || true)"
    [[ -z "$route" ]] && return 0
    clean="$(printf '%s\n' "$route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')"
    # shellcheck disable=SC2086
    ip route change $clean initcwnd 32 initrwnd 32 2>/dev/null || true
}

apply_netdev_tuning() {
    [[ -z "$PRIMARY_IFACE" ]] && return 0
    is_container && return 0
    if command_exists ethtool || ensure_packages ethtool; then
        if [[ "$VIRT_KIND" == "none" ]]; then
            ethtool -G "$PRIMARY_IFACE" rx 1024 2>/dev/null || true
            ethtool -G "$PRIMARY_IFACE" tx 2048 2>/dev/null || true
        else
            ethtool -K "$PRIMARY_IFACE" tso off gso off gro off 2>/dev/null || true
        fi
    fi
    ip link set dev "$PRIMARY_IFACE" txqueuelen 10000 2>/dev/null || true
}

apply_conntrack_tuning() {
    compute_memory_params
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        sysctl -w "net.netfilter.nf_conntrack_max=${CONNTRACK_MAX}" >/dev/null 2>&1 || true
    fi
}

write_boot_apply() {
    write_file "$BOOT_APPLY_BIN" 0755 <<'EOF'
#!/usr/bin/env bash
# Alpine Optimize boot-time network re-apply (fq / initcwnd / netdev)
set -Eeuo pipefail

primary_iface() {
    ip -o -4 route show to default 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' \
        | cut -d'@' -f1
}

is_vm() {
    grep -qw hypervisor /proc/cpuinfo 2>/dev/null
}

for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev="$(basename "$d")"
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*|cni*|flannel*|cali*) continue ;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done

iface="$(primary_iface || true)"
if [ -n "${iface:-}" ]; then
    ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
    if command -v ethtool >/dev/null 2>&1; then
        if is_vm; then
            ethtool -K "$iface" tso off gso off gro off 2>/dev/null || true
        else
            ethtool -G "$iface" rx 1024 2>/dev/null || true
            ethtool -G "$iface" tx 2048 2>/dev/null || true
        fi
    fi
fi

route="$(ip -o -4 route show to default 2>/dev/null | head -n1 || true)"
if [ -n "$route" ]; then
    clean="$(printf '%s\n' "$route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')"
    # shellcheck disable=SC2086
    ip route change $clean initcwnd 32 initrwnd 32 2>/dev/null || true
fi

if command -v iptables >/dev/null 2>&1; then
    tag="alpine-optimize-mss"
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
fi
EOF

    mkdir -p /etc/local.d
    write_file "$BOOT_APPLY_LOCAL" 0755 <<EOF
#!/bin/sh
# Managed by Alpine Optimize
exec ${BOOT_APPLY_BIN}
EOF
    if [[ -x /etc/init.d/local ]]; then
        service_enable local
    fi
}

write_sysctl_bbr_network() {
    local bandwidth="${1:-1000}"
    local region="${2:-asia}"
    local buffer_mb buffer_bytes rmem_max wmem_max sysctl_log extra_conntrack=""

    compute_memory_params
    buffer_mb="$(calculate_buffer_mb "$bandwidth" "$region")"
    buffer_bytes=$((buffer_mb * 1024 * 1024))
    rmem_max="$buffer_bytes"
    wmem_max="$buffer_bytes"
    clean_sysctl_conflicts

    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        extra_conntrack="net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}"
    fi

    write_file "$SYSCTL_FILE" 0644 <<EOF
# Alpine Optimize ${OPTIMIZE_VERSION}
# Generated: $(iso_now)
# Bandwidth: ${bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB
# Official BBR only. Drop-in file — does not replace /etc/sysctl.conf

# --- Congestion control & qdisc ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Socket / TCP buffers (BDP-aware) ---
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Throughput / latency behavior ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# --- Queues / ports ---
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535

# --- UDP (QUIC etc.) ---
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- VM ---
fs.file-max = ${FILE_MAX}
vm.swappiness = ${SWAPPINESS}
vm.dirty_background_bytes = ${DIRTY_BG}
vm.dirty_bytes = ${DIRTY_BYTES}
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.overcommit_memory = 1

# --- Light hardening (non-router VPS) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.dmesg_restrict = 1
${extra_conntrack}
EOF

    info "应用 sysctl：${SYSCTL_FILE}"
    sysctl_log="$(mktemp)"
    register_temp "$sysctl_log"
    if ! sysctl -e -p "$SYSCTL_FILE" >"$sysctl_log" 2>&1; then
        warn "部分 sysctl 参数可能不被当前内核支持："
        grep -iE 'error|cannot|unknown|invalid' "$sysctl_log" 2>/dev/null | head -n 8 || true
    fi
    ok "TCP 缓冲 ${buffer_mb} MB 已写入并尝试应用"
}

do_bootstrap() {
    title "=== 引导：community 源 + GNU 工具 ==="
    enable_community_repo
    apk update >/dev/null
    ensure_packages \
        bash curl ca-certificates coreutils util-linux findutils \
        grep gawk sed procps-ng iproute2 iputils shadow tzdata
    ok "基础工具与 community 源已就绪。"
}

do_time_sync() {
    title "=== 时区与时间同步 ==="
    ensure_packages tzdata

    if [[ -n "$TIMEZONE" ]]; then
        if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
            cp -f "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
            printf '%s\n' "$TIMEZONE" >/etc/timezone
            ok "时区已设为 ${TIMEZONE}"
        else
            warn "未知时区：${TIMEZONE}，跳过。"
        fi
    elif [[ "$NONINTERACTIVE" -eq 0 ]]; then
        local tz
        ask tz "时区（留空跳过，例如 Asia/Shanghai）: "
        if [[ -n "$tz" && -f "/usr/share/zoneinfo/${tz}" ]]; then
            TIMEZONE="$tz"
            cp -f "/usr/share/zoneinfo/${tz}" /etc/localtime
            printf '%s\n' "$tz" >/etc/timezone
            ok "时区已设为 ${tz}"
        fi
    fi

    if is_container; then
        info "容器环境通常由宿主机同步时间，跳过 chrony。"
        return 0
    fi

    if confirm "安装并启用 chrony 时间同步？" "y"; then
        ensure_packages chrony
        if [[ -x /etc/init.d/chronyd ]]; then
            service_enable chronyd
            service_restart chronyd >/dev/null 2>&1 || service_start chronyd >/dev/null 2>&1 || true
            ok "chrony 已启用"
        fi
    fi
}

do_entropy() {
    title "=== 熵源（haveged） ==="
    if is_container; then
        info "容器环境跳过 haveged。"
        return 0
    fi
    ensure_packages haveged
    if [[ -x /etc/init.d/haveged ]]; then
        service_enable haveged
        service_restart haveged >/dev/null 2>&1 || service_start haveged >/dev/null 2>&1 || true
        ok "haveged 已启用"
    fi
}

do_bbr_network_tune() {
    title "=== 1) 官方 BBR + 网络调优 ==="

    if is_container; then
        warn "检测到容器环境（${VIRT_TECH}）。多数网络内核参数由宿主机控制。"
        if ! confirm "仍尝试启用可用的 BBR/sysctl 项？" "n"; then
            return 0
        fi
    fi

    prompt_bandwidth_and_region
    BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-1000}"
    REGION="${REGION:-asia}"

    info "检查官方 BBR..."
    if ! enable_bbr_module; then
        return 1
    fi

    info "写入并应用网络 sysctl..."
    write_sysctl_bbr_network "$BANDWIDTH_MBPS" "$REGION"
    apply_conntrack_tuning

    info "应用 fq 队列 / MSS clamp / initcwnd / 网卡调优..."
    apply_tc_fq
    apply_mss_clamp
    apply_initcwnd
    apply_netdev_tuning
    write_boot_apply

    local cc qdisc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    echo
    if [[ "$cc" == "bbr" ]]; then
        ok "拥塞控制: bbr | 默认队列: ${qdisc}"
    else
        warn "拥塞控制当前为 ${cc}（期望 bbr）。可重启后复查。"
        NEED_REBOOT=1
    fi

    save_state
    opt_log INFO "BBR+network tuned: bw=${BANDWIDTH_MBPS} region=${REGION} cc=${cc}"
    ok "BBR + 网络调优完成。"
}

do_resource_limits() {
    title "=== 2) 系统资源限制（文件句柄） ==="
    mkdir -p "$(dirname "$LIMITS_FILE")"
    write_file "$LIMITS_FILE" 0644 <<'EOF'
# Alpine Optimize — process file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    ok "已写入 ${LIMITS_FILE}"

    if [[ -f "$RC_CONF" || -d /etc ]]; then
        backup_if_exists "$RC_CONF"
        replace_managed_block "$RC_CONF" "$RC_BEGIN" "$RC_END" 'rc_ulimit="-n 1048576"'
        ok "已在 ${RC_CONF} 写入 rc_ulimit（OpenRC 服务默认句柄上限）"
        NEED_REBOOT=1
    fi

    ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true
    ok "资源限制配置完成。"
}

recommended_swap_mb() {
    if   (( MEM_MB < 512 ));  then echo 1024
    elif (( MEM_MB < 1024 )); then echo $(( MEM_MB * 2 ))
    elif (( MEM_MB < 2048 )); then echo $(( MEM_MB * 3 / 2 ))
    elif (( MEM_MB < 4096 )); then echo "$MEM_MB"
    else echo 4096
    fi
}

add_swapfile() {
    local size_mb="$1"
    local swapfile="/swapfile"

    if grep -q " ${swapfile} " /proc/swaps 2>/dev/null; then
        swapoff "$swapfile" 2>/dev/null || true
    fi
    rm -f "$swapfile"

    info "创建 ${size_mb}MB SWAP：${swapfile}"
    if ! fallocate -l "$((size_mb))M" "$swapfile" 2>/dev/null; then
        dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=none 2>/dev/null \
            || dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb"
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"
    if ! grep -qE '^\s*/swapfile\s' /etc/fstab 2>/dev/null; then
        printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
    fi
    ok "SWAP ${size_mb}MB 已启用"
}

do_swap_tune() {
    title "=== 3) 内存与 SWAP 调优 ==="
    local swap_total recommended
    swap_total="$(swap_total_mb)"
    swap_total="${swap_total:-0}"
    recommended="$(recommended_swap_mb)"

    echo "物理内存: ${MEM_MB} MB"
    echo "当前 SWAP: ${swap_total} MB"
    echo "推荐 SWAP: ${recommended} MB（由本脚本管理 /swapfile）"
    echo

    if is_container; then
        warn "容器环境通常无法自行配置 SWAP，已跳过。"
        return 0
    fi

    if (( swap_total == 0 )) || (( swap_total < recommended / 2 )); then
        if confirm "是否创建/调整 /swapfile 为 ${recommended}MB？" "y"; then
            add_swapfile "$recommended"
        fi
    else
        ok "当前 SWAP 已足够，无需强制调整。"
        if confirm "仍要强制重建为 ${recommended}MB？" "n"; then
            add_swapfile "$recommended"
        fi
    fi

    if [[ ! -f "$SYSCTL_FILE" ]]; then
        compute_memory_params
        write_file /etc/sysctl.d/98-alpine-optimize-vm.conf 0644 <<EOF
# Alpine Optimize VM helpers
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 50
EOF
        sysctl -e -p /etc/sysctl.d/98-alpine-optimize-vm.conf >/dev/null 2>&1 || true
    fi
    ok "内存/SWAP 调优完成。"
}

do_disk_tune() {
    title "=== 4) 磁盘优化（noatime） ==="
    if is_container; then
        warn "容器环境跳过 fstab 修改。"
        return 0
    fi
    if [[ ! -f /etc/fstab ]]; then
        warn "未找到 /etc/fstab，跳过。"
        return 0
    fi

    backup_if_exists /etc/fstab
    local root_src root_fstype uuid
    if command_exists findmnt; then
        root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
        root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
        uuid="$(findmnt -no UUID / 2>/dev/null || true)"
    else
        root_src="$(awk '$2=="/" {print $1; exit}' /proc/mounts)"
        root_fstype="$(awk '$2=="/" {print $3; exit}' /proc/mounts)"
    fi

    if [[ -z "$root_src" ]]; then
        warn "无法检测根分区，跳过。"
        return 0
    fi
    case "$root_fstype" in
        ext4|ext3|xfs|btrfs) ;;
        *)
            warn "根文件系统为 ${root_fstype:-unknown}，谨慎跳过自动改 fstab。"
            return 0
            ;;
    esac

    if awk -v src="$root_src" '
        $1 == src || index($1, src) {
            if ($4 ~ /(^|,)noatime(,|$)/) found=1
        }
        END { exit found ? 0 : 1 }
    ' /etc/fstab; then
        ok "根分区已包含 noatime。"
    else
        if [[ -n "$uuid" ]] && grep -q "UUID=${uuid}" /etc/fstab; then
            sed -i -E "s|(UUID=${uuid}[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)|\1\2,noatime|" /etc/fstab
            sed -i -E "s/,noatime,noatime/,noatime/g" /etc/fstab
        else
            sed -i -E "s|(${root_src//\//\\/}[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)|\1\2,noatime|" /etc/fstab
        fi
        ok "已尝试为根分区添加 noatime"
    fi

    if mount -o remount,noatime / 2>/dev/null; then
        ok "已 remount / 使用 noatime"
    else
        warn "即时 remount 失败。重启后 fstab 生效。"
    fi
}

do_install_tools() {
    title "=== 5) 安装常用运维工具 ==="
    enable_community_repo
    ensure_packages \
        curl wget ca-certificates htop iftop iotop vim iproute2 ethtool \
        mtr tcpdump bind-tools iperf3 lsof bash
    ok "工具安装完成。"
}

do_cleanup_cron() {
    title "=== 6) 定时清理任务 ==="
    mkdir -p /etc/periodic/daily
    write_file "$CLEAN_SCRIPT" 0755 <<'EOF'
#!/bin/sh
# Alpine Optimize daily cleanup — safe defaults
apk cache clean >/dev/null 2>&1 || true
find /var/log -type f -name '*.gz' -mtime +14 -delete 2>/dev/null || true
find /var/log -type f -name '*.old' -mtime +14 -delete 2>/dev/null || true
find /tmp -type f -atime +7 -delete 2>/dev/null || true
EOF
    ensure_crond
    ok "已配置每日清理：${CLEAN_SCRIPT}"
}

ensure_sshd_dropin_dir() {
    mkdir -p /etc/ssh/sshd_config.d
    if [[ -f /etc/ssh/sshd_config ]] && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
        backup_if_exists /etc/ssh/sshd_config
        printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >>/etc/ssh/sshd_config
    fi
}

do_ssh_key() {
    title "=== 7) SSH 密钥登录配置 ==="
    local ssh_dir="${HOME}/.ssh"
    local key_path="${ssh_dir}/id_ed25519"
    local pub_path="${key_path}.pub"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ -f "$key_path" ]]; then
        ok "已存在密钥：${key_path}"
    elif [[ -f "${ssh_dir}/id_rsa" ]]; then
        ok "已存在 RSA 密钥：${ssh_dir}/id_rsa（保留不覆盖）"
        key_path="${ssh_dir}/id_rsa"
        pub_path="${key_path}.pub"
    else
        info "生成 ed25519 密钥..."
        ssh-keygen -t ed25519 -f "$key_path" -q -N "" -C "alpine@$(short_hostname)"
        ok "已生成：${key_path}"
    fi

    touch "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    if [[ -f "$pub_path" ]] && ! grep -qF "$(cat "$pub_path")" "${ssh_dir}/authorized_keys" 2>/dev/null; then
        cat "$pub_path" >>"${ssh_dir}/authorized_keys"
        ok "公钥已写入 authorized_keys"
    fi

    ensure_sshd_dropin_dir
    write_file "$SSH_PUBKEY_DROPIN" 0644 <<'EOF'
# Alpine Optimize — enable public key authentication
PubkeyAuthentication yes
EOF
    if reload_sshd; then
        ok "已启用 PubkeyAuthentication"
    else
        warn "sshd 配置校验失败，已保留 drop-in，请手动检查。"
    fi

    echo
    warn "私钥如下（请立即保存到本地安全位置）："
    echo "---------- PRIVATE KEY ----------"
    cat "$key_path"
    echo "---------------------------------"
    echo
    if confirm "确认密钥登录可用后，是否禁用密码登录？（危险，默认否）" "n"; then
        write_file "$SSH_KEYONLY_DROPIN" 0644 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
        if reload_sshd; then
            ok "已禁用密码登录。请确保另开会话能用密钥登录！"
        else
            rm -f "$SSH_KEYONLY_DROPIN"
            err "sshd -t 失败，未禁用密码登录。"
        fi
    else
        info "保留密码登录。"
    fi
}

do_status() {
    title "=== 当前优化状态 ==="
    echo "系统:     ${OS_NAME:-unknown}"
    echo "虚拟化:   ${VIRT_KIND} (${VIRT_TECH})"
    echo "内存:     ${MEM_MB} MB"
    echo "主网卡:   ${PRIMARY_IFACE:-unknown}"
    echo "内核:     $(uname -r 2>/dev/null || echo n/a)"
    echo
    echo "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
    echo "可用算法: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo n/a)"
    echo "默认队列: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
    echo "rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a)"
    echo "wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null || echo n/a)"
    echo "TFO:      $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo n/a)"
    echo "swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo n/a)"
    echo
    if [[ -f "$SYSCTL_FILE" ]]; then
        ok "sysctl drop-in: ${SYSCTL_FILE}"
    else
        dim "sysctl drop-in: 未安装"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        echo "---- state ----"
        cat "$STATE_FILE"
    fi
    echo
    echo "默认路由:"
    ip -4 route show default 2>/dev/null || true
    echo
    echo "SWAP:"
    if [[ -r /proc/swaps ]]; then
        cat /proc/swaps
    else
        free -h 2>/dev/null | grep -i swap || true
    fi
}

do_uninstall() {
    title "=== 卸载 / 还原本脚本优化配置 ==="
    if ! confirm "将移除 Alpine Optimize 写入的配置与开机脚本，是否继续？" "n"; then
        info "已取消。"
        return 0
    fi

    rm -f "$BOOT_APPLY_LOCAL" "$BOOT_APPLY_BIN"
    rm -f "$SYSCTL_FILE" \
          /etc/sysctl.d/98-alpine-optimize-vm.conf \
          "$LIMITS_FILE" \
          "$MODULES_LOAD_FILE" \
          "$SSH_PUBKEY_DROPIN" \
          "$SSH_KEYONLY_DROPIN" \
          "$CLEAN_SCRIPT"
    remove_managed_block "$RC_CONF" "$RC_BEGIN" "$RC_END"

    if command_exists iptables; then
        local tag="alpine-optimize-mss"
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
    fi

    if [[ -f /etc/modules ]]; then
        sed -i '/^tcp_bbr$/d' /etc/modules 2>/dev/null || true
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
    ok "已移除本脚本管理的优化配置。/swapfile 与 fstab noatime 如已修改需自行还原。"
    warn "备份文件后缀：*.alpine.bak"
}

do_all() {
    title "=== 一键全量优化 ==="
    echo "将依次执行："
    echo "  0. 引导（community 源 + GNU 工具）"
    echo "  1. 官方 BBR + 网络调优"
    echo "  2. 系统资源限制"
    echo "  3. 内存与 SWAP"
    echo "  4. 磁盘 noatime"
    echo "  5. 常用工具"
    echo "  6. 定时清理"
    echo "  7. 时间同步 / 熵源"
    echo
    dim "（不含 SSH 密钥：涉及登录安全，请单独选择）"
    echo
    if ! confirm "开始一键优化？" "y"; then
        return 0
    fi

    do_bootstrap
    do_bbr_network_tune
    do_resource_limits
    do_swap_tune
    do_disk_tune
    do_install_tools
    do_cleanup_cron
    do_time_sync
    do_entropy

    echo
    ok "一键优化流程结束。"
    do_status
    if [[ "$NEED_REBOOT" -eq 1 ]]; then
        warn "建议重启以使 rc_ulimit / 模块加载完全生效：reboot"
        if confirm "现在重启？" "n"; then
            reboot
        fi
    fi
}

optimize_usage() {
    cat <<EOF
Alpine 系统优化  v${OPTIMIZE_VERSION}

用法:
  bash alpine.sh optimize                 交互式菜单
  bash alpine.sh optimize --all           一键全量优化
  bash alpine.sh optimize --bootstrap     community 源 + GNU 工具
  bash alpine.sh optimize --bbr           仅 BBR + 网络
  bash alpine.sh optimize --limits        仅资源限制
  bash alpine.sh optimize --swap          仅 SWAP
  bash alpine.sh optimize --disk          仅磁盘
  bash alpine.sh optimize --tools         仅工具
  bash alpine.sh optimize --clean         仅定时清理
  bash alpine.sh optimize --time          时区 / chrony
  bash alpine.sh optimize --entropy       haveged
  bash alpine.sh optimize --ssh-key       SSH 密钥
  bash alpine.sh optimize --status        查看状态
  bash alpine.sh optimize --uninstall     卸载配置

选项:
  -y, --yes                    对确认项默认 yes
  --bandwidth <Mbps>           非交互带宽
  --region <asia|overseas>     服务地区
  --tz <Area/City>             时区，例如 Asia/Shanghai
EOF
}

optimize_parse_and_run() {
    local actions=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) optimize_usage; return 0 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --bandwidth)
                BANDWIDTH_MBPS="${2:-}"; shift 2
                [[ "$BANDWIDTH_MBPS" =~ ^[0-9]+$ ]] || die "--bandwidth 需要正整数 Mbps"
                ;;
            --region)
                REGION="${2:-asia}"; shift 2
                case "$REGION" in asia|overseas) ;; *) die "--region 应为 asia 或 overseas" ;; esac
                ;;
            --tz|--timezone) TIMEZONE="${2:-}"; shift 2 ;;
            --all) actions+=("all"); NONINTERACTIVE=1; shift ;;
            --bootstrap) actions+=("bootstrap"); NONINTERACTIVE=1; shift ;;
            --bbr|--network) actions+=("bbr"); NONINTERACTIVE=1; shift ;;
            --limits) actions+=("limits"); NONINTERACTIVE=1; shift ;;
            --swap) actions+=("swap"); NONINTERACTIVE=1; shift ;;
            --disk) actions+=("disk"); NONINTERACTIVE=1; shift ;;
            --tools) actions+=("tools"); NONINTERACTIVE=1; shift ;;
            --clean) actions+=("clean"); NONINTERACTIVE=1; shift ;;
            --time) actions+=("time"); NONINTERACTIVE=1; shift ;;
            --entropy) actions+=("entropy"); NONINTERACTIVE=1; shift ;;
            --ssh-key) actions+=("ssh"); NONINTERACTIVE=1; shift ;;
            --status) actions+=("status"); NONINTERACTIVE=1; shift ;;
            --uninstall) actions+=("uninstall"); NONINTERACTIVE=1; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    ((${#actions[@]} > 0)) || return 1
    local a
    for a in "${actions[@]}"; do
        case "$a" in
            all) do_all ;;
            bootstrap) do_bootstrap ;;
            bbr) do_bbr_network_tune ;;
            limits) do_resource_limits ;;
            swap) do_swap_tune ;;
            disk) do_disk_tune ;;
            tools) do_install_tools ;;
            clean) do_cleanup_cron ;;
            time) do_time_sync ;;
            entropy) do_entropy ;;
            ssh) do_ssh_key ;;
            status) do_status ;;
            uninstall) do_uninstall ;;
        esac
    done
    return 0
}

optimize_menu() {
    while true; do
        clear 2>/dev/null || true
        title "Alpine 系统优化  v${OPTIMIZE_VERSION}"
        echo "  系统: ${OS_NAME} | 内存: ${MEM_MB}MB | 虚拟化: ${VIRT_KIND}"
        echo "  网卡: ${PRIMARY_IFACE:-unknown} | 拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
        echo
        echo "────────────────────────────────────────"
        echo "  0) 一键全量优化（推荐）"
        echo "────────────────────────────────────────"
        echo "  1) 官方 BBR + TCP/网络调优"
        echo "  2) 系统资源限制（nofile / OpenRC）"
        echo "  3) 内存与 SWAP"
        echo "  4) 磁盘优化（noatime）"
        echo "  5) 安装常用运维工具"
        echo "  6) 配置每日定时清理"
        echo "  7) SSH 密钥登录"
        echo "  8) 引导（community + GNU 工具）"
        echo "  9) 时区与 chrony"
        echo "  e) 熵源 haveged"
        echo "────────────────────────────────────────"
        echo "  s) 查看当前优化状态"
        echo "  u) 卸载 / 还原优化配置"
        echo "  q) 返回"
        echo "────────────────────────────────────────"
        local choice
        ask choice "请选择: "
        case "$choice" in
            0) do_all; pause ;;
            1) do_bbr_network_tune; pause ;;
            2) do_resource_limits; pause ;;
            3) do_swap_tune; pause ;;
            4) do_disk_tune; pause ;;
            5) do_install_tools; pause ;;
            6) do_cleanup_cron; pause ;;
            7) do_ssh_key; pause ;;
            8) do_bootstrap; pause ;;
            9) do_time_sync; pause ;;
            e|E) do_entropy; pause ;;
            s|S) do_status; pause ;;
            u|U) do_uninstall; pause ;;
            q|Q|exit) return 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

optimize_main() {
    require_root
    require_alpine
    detect_system
    ensure_opt_dirs
    opt_log INFO "start v${OPTIMIZE_VERSION} os=${OS_NAME} mem=${MEM_MB} virt=${VIRT_KIND}"
    if [[ $# -gt 0 ]]; then
        optimize_parse_and_run "$@" && return 0
    fi
    optimize_menu
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    optimize_main "$@"
fi
