#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# 仅加载定义，永不进入安装、主菜单或真实防火墙。
source <(sed '/^# ============== 入口 ==============/,$d' "$ROOT/nft.sh")
CONF_DIR="$TMP"
CONF_FILE="$TMP/forward.conf"
get_local_ip() { printf '192.0.2.1\n'; }
err() { :; }
MODE=ok
nft() {
    case "$*" in
        "list table ip sing_port_forward") return 0 ;;
        "-c -f "*)
            grep -qx 'delete table ip sing_port_forward' "$3"
            grep -q 'table ip sing_port_forward {' "$3"
            [[ "$MODE" != invalid ]] ;;
        "-f "*)
            [[ "$MODE" != reject ]] || return 1
            cp "$2" "$TMP/applied" ;;
        *) printf 'unexpected nft operation: %s\n' "$*" >&2; exit 1 ;;
    esac
}
printf 'old configuration\n' >"$CONF_FILE"
for MODE in invalid reject; do
    RULES=('41000|192.0.2.2|443')
    write_conf_file
    if reload_rules; then exit 1; fi
    [[ "$(cat "$CONF_FILE")" == 'old configuration' ]]
    [[ ! -f "$TMP/applied" ]]
done
MODE=ok
write_conf_file
reload_rules
[[ -f "$TMP/applied" && ! -f "$CONF_FILE.previous" ]]
grep -q 'dnat to 192.0.2.2:443' "$CONF_FILE"
printf 'ok - nft candidate validation and atomic replacement preserve running rules and persistence on failure\n'
