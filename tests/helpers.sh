#!/usr/bin/env bash
# Sourced by tests only. All fixtures and service paths stay below one temp dir.
set -eo pipefail
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sing-lite-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
export SING_TEST_CFG="$TEST_TMP/config with spaces"
export SING_TEST_SYSTEMD_DIR="$TEST_TMP/systemd"
export SING_TEST_OPENRC_DIR="$TEST_TMP/openrc"
# Keep old source guards isolated while the new identity is being implemented.
export VLESS_TEST_CFG="$SING_TEST_CFG"
export VLESS_TEST_SYSTEMD_DIR="$SING_TEST_SYSTEMD_DIR"
export VLESS_TEST_OPENRC_DIR="$SING_TEST_OPENRC_DIR"
mkdir -p "$SING_TEST_CFG" "$SING_TEST_SYSTEMD_DIR" "$SING_TEST_OPENRC_DIR"
source "$TEST_ROOT/vless-server.sh"
[[ "$CFG" == "$SING_TEST_CFG" && "$SYSTEMD_DIR" == "$SING_TEST_SYSTEMD_DIR" && "$OPENRC_DIR" == "$SING_TEST_OPENRC_DIR" ]]
DISTRO=debian
_log() { :; }
_header() { :; }
_pause() { :; }
_item() { :; }
_ok() { :; }
_listen_addr() { printf '127.0.0.1\n'; }
get_connection_addresses() { printf '192.0.2.1|2001:db8::1\n'; }
get_ip_country() { printf 'TEST\n'; }
forbidden() { printf 'FAIL: unexpected host operation: %s\n' "$*" >&2; exit 90; }
svc() { forbidden svc "$@"; }
systemctl() { forbidden systemctl "$@"; }
rc-service() { forbidden rc-service "$@"; }
iptables() { forbidden iptables "$@"; }
ip6tables() { forbidden ip6tables "$@"; }
nft() { forbidden nft "$@"; }
curl() { forbidden curl "$@"; }
sing-box() {
    if [[ -n "${SING_TEST_SINGBOX_BIN:-}" ]]; then
        "$SING_TEST_SINGBOX_BIN" "$@"
        return $?
    fi
    case "$1" in
        version) printf 'sing-box version 1.14.4\n' ;;
        check) [[ "$2" == -c ]] && jq empty "$3" ;;
        *) forbidden sing-box "$@" ;;
    esac
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_json() { jq -e "$1" "${2:-$CFG/singbox.json}" >/dev/null || fail "$1"; }
rewrite_db() {
    jq "$1" "$DB_FILE" >"$TEST_TMP/db.next"
    mv "$TEST_TMP/db.next" "$DB_FILE"
}
