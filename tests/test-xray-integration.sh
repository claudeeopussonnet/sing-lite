#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

init_db
[[ "$XRAY_PROTOCOLS" == 'vless vless-xhttp vless-enc' ]] || fail 'Xray registry'
for protocol in $XRAY_PROTOCOLS; do
    for resolver in protocol_core protocol_db_core protocol_subscription_db_core protocol_uninstall_db_core; do
        [[ "$($resolver "$protocol")" == xray ]] || fail "$resolver $protocol"
    done
    [[ "${PROTO_SVC[$protocol]}" == sing-xray && "${PROTO_BIN[$protocol]}" == xray ]] || fail 'Xray service identity'
done
select_vless_mode <<< $'1\n1' >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-singbox ]] || fail 'native reality selection'
select_vless_mode <<< $'1\n2' >/dev/null
[[ "$SELECTED_PROTOCOL" == vless ]] || fail 'Xray reality selection'
select_vless_mode <<< 2 >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-xhttp ]] || fail 'XHTTP selection'
select_vless_mode <<< 3 >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-enc ]] || fail 'Encryption selection'
if select_vless_mode <<< 0 >/dev/null; then fail 'VLESS cancel'; fi
if select_vless_mode </dev/null; then fail 'VLESS EOF'; fi

# Migration preserves native records and Xray credentials, including leading zeroes.
db_add singbox socks '{"port":42001,"username":"native","password":"native-password"}'
db_add xray vless '{"port":42002,"uuid":"11111111-1111-4111-8111-111111111111","short_id":"0001"}'
db_migrate_to_multiuser
assert_json '.xray.vless.users[0].uuid == .xray.vless.uuid and .xray.vless.short_id == "0001" and .singbox.socks.users[0].uuid == "native-password"' "$DB_FILE"
[[ "$(get_xray_protocols)" == vless ]] || fail 'Xray installed listing'
if check_port_conflict 42002 socks singbox >/dev/null; then fail 'Xray collision missed'; fi
if check_port_conflict 42001 vless xray >/dev/null; then fail 'native collision missed'; fi

# Service files use owned paths and validate the config before launch.
systemctl() { [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"; }
create_xray_service
grep -F "ExecStartPre=\"$CFG/bin/xray\" run -test -c \"$CFG/xray.json\"" "$SYSTEMD_DIR/sing-xray.service" >/dev/null || fail 'systemd validation'
DISTRO=alpine
create_xray_service
grep -F "start_pre() { \"$CFG/bin/xray\" run -test -c \"$CFG/xray.json\"; }" "$OPENRC_DIR/sing-xray" >/dev/null || fail 'OpenRC validation'
[[ -x "$OPENRC_DIR/sing-xray" ]] || fail 'OpenRC executable'
DISTRO=debian
create_server_scripts
bash -n "$CFG/watchdog.sh"
grep -F 'sing-xray:xray' "$CFG/watchdog.sh" >/dev/null || fail 'watchdog identity'
grep -F 'xray run -test -c "$CFG/xray.json"' "$CFG/watchdog.sh" >/dev/null || fail 'watchdog validation'
[[ "$(owned_services)" == *sing-xray* ]] || fail 'stop/uninstall ownership'
_runtime_config_service_pid() { printf '0\n'; }
printf '{"test":"xray runtime"}\n' >"$CFG/xray.json"
show_runtime_config xray >"$TEST_TMP/runtime"
grep -F 'xray runtime' "$TEST_TMP/runtime" >/dev/null || fail 'runtime viewer'

# The key parser accepts the current upstream labels and keeps one matching pair.
xray() {
    case "$1" in
        x25519) printf 'PrivateKey: %043d\nPassword (PublicKey): %043d\nHash32: ignored\n' 1 2 ;;
        vlessenc) printf '"decryption": "mlkem768x25519plus.native.600s.server_key"\n"encryption": "mlkem768x25519plus.native.0rtt.client_key"\n"decryption": "mlkem768x25519plus.native.600s.other_server"\n"encryption": "mlkem768x25519plus.native.0rtt.other_client"\n' ;;
        *) forbidden xray "$@" ;;
    esac
}
keys=$(gen_xray_reality_keys)
[[ "$(jq -r '.public_key' <<<"$keys")" == 0000000000000000000000000000000000000000002 ]] || fail 'current x25519 labels'
keys=$(gen_xray_encryption)
[[ "$(jq -r '.decryption' <<<"$keys")" == mlkem768x25519plus.native.600s.server_key ]] || fail 'first server encryption pair'
[[ "$(jq -r '.encryption' <<<"$keys")" == mlkem768x25519plus.native.0rtt.client_key ]] || fail 'matching client encryption pair'
(
    _apply_xray_config() { printf '%s\n' "$1" >"$TEST_TMP/wizard-record.json"; }
    configure_xray_vless vless-enc 42003 </dev/null
    assert_json '.users == [{name:"default",uuid:.uuid,enabled:true}]' "$TEST_TMP/wizard-record.json"
    INSTALL_MODE=replace REPLACE_PORT=42003 configure_xray_vless vless-enc 42003 </dev/null
    assert_json 'has("users") | not' "$TEST_TMP/wizard-record.json"
)
(
    db_list_users() { printf 'default\n'; }
    db_get_user() { :; }
    db_add_user() { printf 'add\n' >>"$TEST_TMP/menu-users"; }
    db_del_user() { printf 'remove\n' >>"$TEST_TMP/menu-users"; }
    _regenerate_config() { fail 'Xray user menu restarted after the committed transaction'; }
    _add_user xray vless <<< $'alice\n\n' >"$TEST_TMP/user-menu-output" 2>&1
    db_list_users() { printf 'alice\n'; }
    _delete_user xray vless <<< $'1\ny' >>"$TEST_TMP/user-menu-output" 2>&1
    [[ "$(cat "$TEST_TMP/menu-users")" == $'add\nremove' ]] || fail 'Xray user menu success flow'
)

# User changes reload Xray and expiry scans include its namespace.
rebuild_and_reload_xray() { printf 'xray\n' >>"$TEST_TMP/reloads"; }
_apply_xray_user_change() {
    [[ "$1" == vless && "$2" == enabled && "$3" == default ]] || fail 'Xray user dispatch'
    _db_apply --argjson enabled "$4" '.xray.vless.users[0].enabled=$enabled'
    rebuild_and_reload_xray
}
ensure_expire_check_cron() { return 0; }
crontab() { forbidden crontab "$@"; }
db_set_user_enabled xray vless default false
grep -Fx xray "$TEST_TMP/reloads" >/dev/null || fail 'Xray user reload dispatch'
db_set_user_expire_date xray vless default 2020-01-01
db_set_user_enabled xray vless default true
[[ "$(db_get_expired_users)" == *'xray|vless|default|'* ]] || fail 'Xray expiry enumeration'
if _set_user_routing xray vless >/dev/null 2>&1; then fail 'Xray exposes sing-box user routing'; fi

# Global start requests activation; account rebuilds use the default stopped-state behavior.
(
    db_del singbox socks
    create_server_scripts() { :; }
    create_watchdog_service() { :; }
    install_xray() { :; }
    svc() { [[ "$2" == sing-watchdog ]] || forbidden svc "$@"; }
    rebuild_and_reload_xray() { printf '%s\n' "${1:-}" >>"$TEST_TMP/activation-modes"; }
    start_services
    [[ "$(cat "$TEST_TMP/activation-modes")" == start ]] || fail 'global start leaves Xray stopped'
)

# Automatic repair is scoped to the owned core and respects the pause marker.
mkdir -p "$CFG/bin"
printf '#!/bin/bash\nexit 1\n' >"$CFG/bin/xray"
chmod 755 "$CFG/bin/xray"
rebuild_and_reload_xray() { printf '%s\n' "${1:-}" >>"$TEST_TMP/repairs"; }
touch "$CFG/paused"
ensure_xray_runtime_consistency
[[ ! -e "$TEST_TMP/repairs" ]] || fail 'paused Xray auto-repaired'
rm "$CFG/paused"
ensure_xray_runtime_consistency >/dev/null 2>&1
[[ "$(cat "$TEST_TMP/repairs")" == start ]] || fail 'Xray auto-repair did not activate owned service'
printf 'ok - Xray menus, ownership, services, keys and users\n'
