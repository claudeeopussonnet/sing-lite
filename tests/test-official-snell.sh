#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { :; }
SERVICE_RUNNING=false
SERVICE_ENABLED=false
FAIL_AT=''
svc() {
    [[ "$2" == "$SERVICE" ]] || forbidden svc "$@"
    printf '%s\n' "$1" >>"$TEST_TMP/service-calls"
    case "$1" in
        status) [[ "$SERVICE_RUNNING" == true ]] ;;
        enabled) [[ "$SERVICE_ENABLED" == true ]] ;;
        enable)
            SERVICE_ENABLED=true
            [[ "$FAIL_AT" != enable ]] || { FAIL_AT=''; return 1; } ;;
        disable) SERVICE_ENABLED=false ;;
        stop) SERVICE_RUNNING=false ;;
        start|restart)
            SERVICE_RUNNING=false
            if [[ "$FAIL_AT" == activation ]]; then FAIL_AT=''; return 1; fi
            SERVICE_RUNNING=true ;;
        *) forbidden svc "$@" ;;
    esac
}
systemctl() { [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"; }
create_service() {
    [[ "$1" == "$PROTOCOL" ]] || fail 'wrong official service created'
    printf 'candidate service\n' >"$SYSTEMD_DIR/$SERVICE.service"
    printf 'candidate service\n' >"$OPENRC_DIR/$SERVICE"
    printf 'candidate watchdog\n' >"$SYSTEMD_DIR/sing-watchdog.service"
    printf 'candidate watchdog\n' >"$OPENRC_DIR/sing-watchdog"
    [[ "$FAIL_AT" != definition ]]
}
_wait_for_owned_service() {
    [[ "$1" == "$SERVICE" ]] || fail 'wrong readiness service'
    if [[ "$FAIL_AT" == readiness ]]; then FAIL_AT=''; return 1; fi
    [[ "$SERVICE_RUNNING" == true ]]
}
gen_snell_link() {
    [[ "$FAIL_AT" != configuration ]] || return 1
    printf 'mock-snell://%s:%s?psk=%s&version=%s\n' "$1" "$2" "$3" "$4"
}
seed_fixture() {
    printf '{"singbox":{"socks":{"port":47000}},"snell":{"%s":{"port":47001,"psk":"originalSnellKey123","version":%s}}}\n' "$PROTOCOL" "$VERSION_UNDER_TEST" >"$DB_FILE"
    artifacts=("$DB_FILE" "$CFG/$PROTOCOL.conf" "$CFG/$PROTOCOL.join" "$CFG/join.txt" "$CFG/role"
        "$SYSTEMD_DIR/$SERVICE.service" "$OPENRC_DIR/$SERVICE"
        "$SYSTEMD_DIR/sing-watchdog.service" "$OPENRC_DIR/sing-watchdog")
    local file i=0
    for file in "${artifacts[@]:1}"; do printf 'original %s\n' "$file" >"$file"; done
    chmod 600 "$DB_FILE" "$CFG/$PROTOCOL.conf"
    chmod 640 "$SYSTEMD_DIR/$SERVICE.service" "$SYSTEMD_DIR/sing-watchdog.service"
    chmod 750 "$OPENRC_DIR/$SERVICE" "$OPENRC_DIR/sing-watchdog"
    mkdir -p "$TEST_TMP/expected"
    for file in "${artifacts[@]}"; do cp -p "$file" "$TEST_TMP/expected/$i"; i=$((i+1)); done
    printf 'unrelated shared service\n' >"$SYSTEMD_DIR/sing-singbox.service"
    : >"$TEST_TMP/service-calls"
}
assert_restored() {
    local file i=0
    for file in "${artifacts[@]}"; do
        cmp "$TEST_TMP/expected/$i" "$file" || fail "official rollback changed $file"
        [[ $(stat -c %a "$file") == $(stat -c %a "$TEST_TMP/expected/$i") ]] || fail "official rollback permissions: $file"
        i=$((i+1))
    done
    [[ "$SERVICE_RUNNING" == "$initial_running" && "$SERVICE_ENABLED" == "$initial_enabled" ]] || fail 'official service states not restored'
    grep -qx 'unrelated shared service' "$SYSTEMD_DIR/sing-singbox.service" || fail 'shared service changed'
}
generate_candidate() {
    if [[ "$PROTOCOL" == snell-v6 ]]; then
        gen_snell_v6_server_config 'safeSnell.key_123!@%+=,-~' 47011 6 prefer-ipv4 1.1.1.1 unshaped true
    else
        gen_snell_v5_official_server_config 'safeSnell.key_123!@%+=,-~' 47011
    fi
}
for DISTRO in debian alpine; do
    for PROTOCOL in snell-v5-official snell-v6; do
        SERVICE="${PROTO_SVC[$PROTOCOL]}"
        VERSION_UNDER_TEST=5; [[ "$PROTOCOL" != snell-v6 ]] || VERSION_UNDER_TEST=6
        for initial_running in true false; do
            for initial_enabled in true false; do
                for failure in configuration definition enable activation readiness; do
                    seed_fixture
                    SERVICE_RUNNING="$initial_running"; SERVICE_ENABLED="$initial_enabled"; FAIL_AT="$failure"
                    if generate_candidate; then fail "accepted official $failure failure"; fi
                    assert_restored
                    if [[ "$failure" == configuration ]] && grep -Eq '^(stop|start|restart|enable|disable)$' "$TEST_TMP/service-calls"; then
                        fail 'configuration failure touched running service'
                    fi
                done
            done
        done
        seed_fixture
        SERVICE_RUNNING=false; SERVICE_ENABLED=false; FAIL_AT=''
        generate_candidate
        [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'successful official install not active/enabled'
        assert_json ".snell[\"$PROTOCOL\"] | type == \"object\" and .port == 47011 and .psk == \"safeSnell.key_123!@%+=,-~\"" "$DB_FILE"
        grep -qx 'psk = safeSnell.key_123!@%+=,-~' "$CFG/$PROTOCOL.conf"
        [[ $(stat -c %a "$CFG/$PROTOCOL.conf") == 600 ]] || fail 'official candidate permissions'
        # A fresh-install failure must remove all newly created artifacts.
        seed_fixture
        for file in "${artifacts[@]:1}"; do rm -f "$file"; done
        cp -p "$DB_FILE" "$TEST_TMP/fresh-db"
        SERVICE_RUNNING=false; SERVICE_ENABLED=false; FAIL_AT=activation
        if generate_candidate; then fail 'fresh failed activation accepted'; fi
        cmp "$DB_FILE" "$TEST_TMP/fresh-db"
        for file in "${artifacts[@]:1}"; do [[ ! -e "$file" ]] || fail "fresh failure retained $file"; done
        [[ "$SERVICE_RUNNING" == false && "$SERVICE_ENABLED" == false ]] || fail 'fresh service remained enabled/running'
        # Invalid INI must be rejected before any state changes.
        seed_fixture
        initial_running=true; initial_enabled=true
        SERVICE_RUNNING=true; SERVICE_ENABLED=true; FAIL_AT=''
        printf 'invalid INI\n' >"$TEST_TMP/invalid.conf"
        record=$(jq -nc --argjson version "$VERSION_UNDER_TEST" '{port:47011,psk:"safeSnellKey12345",version:$version}')
        if _apply_official_snell_record "$PROTOCOL" "$record" "$TEST_TMP/invalid.conf"; then fail 'invalid official INI accepted'; fi
        assert_restored
        [[ ! -s "$TEST_TMP/service-calls" ]] || fail 'invalid INI touched service'
    done
done
printf 'ok - official v5/v6 config, service activation and readiness failures restore files, modes and runtime states on systemd/OpenRC\n'

# Exercise the install wizard without installing binaries or touching host services.
select_protocol() { SELECTED_PROTOCOL=vless-ws-notls; }
check_dependencies() { :; }
install_deps() { :; }
ensure_dual_stack_listen() { :; }
install_singbox() { :; }
handle_existing_protocol() { :; }
ask_port() { printf '47021\n'; }
gen_uuid() { printf '00000000-0000-4000-8000-000000000021\n'; }
gen_vless_ws_notls_server_config() { printf 'activated\n' >"$TEST_TMP/activated"; }
create_shortcut() { :; }
show_single_protocol_info() { :; }
create_watchdog_service() {
    [[ -s "$TEST_TMP/activated" && -x "$CFG/watchdog.sh" ]] || fail 'watchdog created before protocol/scripts'
    printf 'mock watchdog\n' >"$SYSTEMD_DIR/sing-watchdog.service"
}
svc() {
    [[ "$2" == sing-watchdog ]] || forbidden svc "$@"
    case "$1" in enable|start) printf '%s\n' "$1" >>"$TEST_TMP/watchdog-calls" ;; *) forbidden svc "$@" ;; esac
}
DISTRO=debian
rm -f "$CFG/sub.info" "$CFG/watchdog.sh" "$TEST_TMP/activated"
do_install_server <<<'/test-ws'
[[ -x "$CFG/watchdog.sh" && -s "$SYSTEMD_DIR/sing-watchdog.service" ]] || fail 'fresh install missing watchdog'
[[ $(cat "$TEST_TMP/watchdog-calls") == $'enable\nstart' ]] || fail 'watchdog not enabled/started'
printf 'ok - fresh shared install creates watchdog script and enabled service without restarting other cores\n'
