#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# A fresh shell restores the production logger without reassigning readonly globals.
# Exported fixture paths from helpers keep sourcing isolated from the host.
bash -e -s -- "$TEST_ROOT/vless-server.sh" "$TEST_TMP/logger.log" <<'LOGGER'
    source "$1"
    LOG_FILE="$2"
    date() { printf '2026-01-02 03:04:05\n'; }
    _log INFO '\e[32m中文日志 [ALL]\e[0m'
    _log WARN '\033[1;33mIPv4\033[0m' '\x1b[36mIPv6\x1b[0m'
    _log INFO $'\033[1;32m实际颜色 中文 [ALL]\033[0m'
    _log INFO '保留 C:\new\test\file \n \t \c \033 \x41 \\ 100% %s'
    _log INFO "${G}[ALL]${NC} ${C}IPv4${NC} ${Y}IPv6${NC}"
LOGGER
cat >"$TEST_TMP/expected-log" <<'LOG'
[2026-01-02 03:04:05] [INFO] 中文日志 [ALL]
[2026-01-02 03:04:05] [WARN] IPv4 IPv6
[2026-01-02 03:04:05] [INFO] 实际颜色 中文 [ALL]
[2026-01-02 03:04:05] [INFO] 保留 C:\new\test\file \n \t \c \033 \x41 \\ 100% %s
[2026-01-02 03:04:05] [INFO] [ALL] IPv4 IPv6
LOG
cmp "$TEST_TMP/expected-log" "$TEST_TMP/logger.log" || fail 'logger changed text or retained SGR colors'
printf 'ok - production logger strips literal/actual SGR and preserves Chinese, labels and backslashes\n'
