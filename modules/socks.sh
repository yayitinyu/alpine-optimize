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

socks_main() {
    local script
    script="$(socks_script_path)"
    [[ -f "$script" ]] || die "找不到 Alpine SOCKS5 脚本：${script}"
    bash "$script" "$@"
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    socks_main "$@"
fi
