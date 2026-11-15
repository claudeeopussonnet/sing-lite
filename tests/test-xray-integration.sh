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
[[ "$SELECTED_PROTOCOL" == vless ]] || fail 'Xray reality selection'
select_vless_mode <<< $'1\n2' >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-singbox ]] || fail 'native reality selection'
select_vless_mode <<< $'\n\n' >/dev/null
[[ "$SELECTED_PROTOCOL" == vless ]] || fail 'default Xray reality selection'
if select_vless_mode <<< $'1\n0' >/dev/null; then fail 'REALITY cancel'; fi
if select_vless_mode <<< 1 >/dev/null; then fail 'REALITY EOF'; fi
select_vless_mode <<< 2 >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-xhttp ]] || fail 'XHTTP selection'
select_vless_mode <<< 3 >/dev/null
[[ "$SELECTED_PROTOCOL" == vless-enc ]] || fail 'Encryption selection'
if select_vless_mode <<< 0 >/dev/null; then fail 'VLESS cancel'; fi
if select_vless_mode </dev/null; then fail 'VLESS EOF'; fi

# Exercise both install/add entry points with every host operation mocked.
(
    check_dependencies() { :; }
    install_deps() { :; }
    ensure_dual_stack_listen() { :; }
    install_xray() { printf 'install:xray\n' >>"$TEST_TMP/wizard-events"; }
    install_singbox() { printf 'install:singbox\n' >>"$TEST_TMP/wizard-events"; }
    handle_existing_protocol() { printf 'existing:%s:%s\n' "$1" "$2" >>"$TEST_TMP/wizard-events"; }
    ask_port() { printf '42044\n'; }
    configure_xray_vless() { printf 'configure:%s:%s\n' "$1" "$2" >>"$TEST_TMP/wizard-events"; }
    gen_singbox_reality_keys() { printf '{"public_key":"test-public","private_key":"test-private"}\n'; }
    ask_sni_config() { printf 'www.example.com\n'; }
    gen_vless_singbox_server_config() { printf 'configure:vless-singbox:%s\n' "$2" >>"$TEST_TMP/wizard-events"; }
    create_server_scripts() { :; }
    create_watchdog_service() { :; }
    create_shortcut() { :; }
    svc() { [[ "$*" == 'enable sing-watchdog' || "$*" == 'start sing-watchdog' ]] || forbidden svc "$@"; }
    show_single_protocol_info() { printf 'show:%s:%s\n' "$1" "$3" >>"$TEST_TMP/wizard-events"; }
    for choice in xray singbox; do
        : >"$TEST_TMP/wizard-events"
        if [[ "$choice" == xray ]]; then
            do_install_server <<< $'1\n\n\n' >/dev/null
            expected=vless
        else
            do_install_server <<< $'1\n1\n2' >/dev/null
            expected=vless-singbox
        fi
        expected_events=$(printf 'install:%s\nexisting:%s:%s\nconfigure:%s:42044\nshow:%s:42044' \
            "$choice" "$expected" "$choice" "$expected" "$expected")
        [[ "$(cat "$TEST_TMP/wizard-events")" == "$expected_events" ]] || fail 'REALITY wizard core dispatch/order'
    done
)

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
    _info() { :; }
    _apply_xray_config() { printf '%s\n' "$1" >"$TEST_TMP/wizard-record.json"; }
    for choice in y Y n N ''; do
        configure_xray_vless vless-enc 42003 <<<"$choice" >/dev/null
        assert_json '.users == [{name:"default",uuid:.uuid,enabled:true}] and
            .transport == "raw" and .security_mode == "encryption"' "$TEST_TMP/wizard-record.json"
        expected_flow=''
        [[ ! "$choice" =~ ^[yY]$ ]] || expected_flow=xtls-rprx-vision
        [[ "$(jq -r '.flow' "$TEST_TMP/wizard-record.json")" == "$expected_flow" ]] || fail 'ENC wizard Vision choice'
    done
    configure_xray_vless vless-enc 42003 <<< $'invalid\ny' >"$TEST_TMP/vision-prompt" 2>&1
    grep -q '请输入 y 或 n' "$TEST_TMP/vision-prompt" || fail 'invalid Vision choice not explained'
    assert_json '.flow == "xtls-rprx-vision"' "$TEST_TMP/wizard-record.json"
    for choice in y n; do
        INSTALL_MODE=replace REPLACE_PORT=42003 configure_xray_vless vless-enc 42003 <<<"$choice" >/dev/null
        assert_json 'has("users") | not' "$TEST_TMP/wizard-record.json"
        expected_flow=''
        [[ "$choice" != y ]] || expected_flow=xtls-rprx-vision
        [[ "$(jq -r '.flow' "$TEST_TMP/wizard-record.json")" == "$expected_flow" ]] || fail 'ENC replacement Vision choice'
    done
    rm -f "$TEST_TMP/wizard-record.json"
    if configure_xray_vless vless-enc 42003 </dev/null >/dev/null; then fail 'ENC Vision EOF accepted'; fi
    if configure_xray_vless vless-enc 42003 <<< invalid >/dev/null 2>&1; then fail 'ENC Vision retry EOF accepted'; fi
    [[ ! -e "$TEST_TMP/wizard-record.json" ]] || fail 'ENC Vision EOF committed configuration'
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
