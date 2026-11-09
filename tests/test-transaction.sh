#!/usr/bin/env bash
# Real protocol/upgrade transactions and file rollback; service operations are local mocks.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { :; }
SERVICE_RUNNING=false
SERVICE_ENABLED=false
FAIL_OPERATION=''
svc() {
    [[ "$2" == sing-singbox ]] || forbidden svc "$@"
    printf '%s\n' "$1" >>"$TEST_TMP/service-calls"
    case "$1" in
        status) [[ "$SERVICE_RUNNING" == true ]] ;;
        enabled) [[ "$SERVICE_ENABLED" == true ]] ;;
        enable) SERVICE_ENABLED=true ;;
        disable) SERVICE_ENABLED=false ;;
        stop) SERVICE_RUNNING=false ;;
        start|restart)
            if [[ "$FAIL_OPERATION" == "$1" ]]; then
                # A failed restart can already have stopped the previous process.
                FAIL_OPERATION=''
                SERVICE_RUNNING=false
                cp "$DB_FILE" "$TEST_TMP/attempted-db"
                cp "$CFG/singbox.json" "$TEST_TMP/attempted-config"
                return 1
            fi
            [[ -f "$SYSTEMD_DIR/sing-singbox.service" ]] || fail 'start without shared service definition'
            SERVICE_RUNNING=true ;;
        *) forbidden svc "$@" ;;
    esac
}
systemctl() {
    [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"
    printf 'daemon-reload\n' >>"$TEST_TMP/service-calls"
}
create_singbox_service() {
    printf 'candidate service: %s/bin/sing-box\n' "$CFG" >"$SYSTEMD_DIR/sing-singbox.service"
    printf 'candidate OpenRC service\n' >"$OPENRC_DIR/sing-singbox"
}
_wait_for_singbox_ready() { [[ "$SERVICE_RUNNING" == true ]]; }

seed_fixture() {
    mkdir -p "$CFG/bin"
    rm -f "$CFG/bin/sing-box"
    cat >"$DB_FILE" <<'JSON'
{"singbox":{"ss-legacy":[{"port":46001,"method":"aes-256-gcm","password":"test-first-password"},{"port":46002,"method":"aes-256-gcm","password":"test-second-password"}],"socks":{"port":46003,"username":"test-user","password":"test-password","auth_mode":"password"}},"snell":{"snell-v6":{"port":46006,"psk":"testOfficialSnellKey6","version":6}},"routing":{"warp_mode":"disabled"}}
JSON
    chmod 600 "$DB_FILE"
    printf 'official Snell JOIN sentinel\n' >"$CFG/snell-v6.join"
    printf 'official Snell configuration sentinel\n' >"$CFG/snell-v6.conf"
    printf 'official Snell service sentinel\n' >"$SYSTEMD_DIR/sing-snell-v6.service"
    generate_singbox_config
    regenerate_singbox_protocol_join_info ss-legacy
    regenerate_singbox_protocol_join_info socks
    printf 'server\n' >"$CFG/role"
    printf 'original systemd service\n' >"$SYSTEMD_DIR/sing-singbox.service"
    printf 'original OpenRC service\n' >"$OPENRC_DIR/sing-singbox"
    chmod 640 "$SYSTEMD_DIR/sing-singbox.service"
    chmod 750 "$OPENRC_DIR/sing-singbox"
    : >"$TEST_TMP/service-calls"
    FAIL_OPERATION=''
}

# Snapshot public artifacts, including other protocols, rather than internal transaction files.
artifacts=("$DB_FILE" "$CFG/singbox.json" "$CFG/ss-legacy.join" "$CFG/socks.join"
    "$CFG/join.txt" "$CFG/role" "$SYSTEMD_DIR/sing-singbox.service" "$OPENRC_DIR/sing-singbox"
    "$CFG/snell-v6.join" "$CFG/snell-v6.conf" "$SYSTEMD_DIR/sing-snell-v6.service")
save_artifacts() {
    local i=0 file
    mkdir -p "$TEST_TMP/expected"
    for file in "${artifacts[@]}"; do
        cp -p "$file" "$TEST_TMP/expected/$i"
        i=$((i + 1))
    done
}
assert_artifacts_restored() {
    local i=0 file
    for file in "${artifacts[@]}"; do
        cmp "$TEST_TMP/expected/$i" "$file" || fail "rollback changed $file"
        [[ "$(stat -c %a "$file")" == "$(stat -c %a "$TEST_TMP/expected/$i")" ]] || fail "rollback permissions: $file"
        i=$((i + 1))
    done
}
replacement='{"port":46011,"method":"aes-256-gcm","password":"test-replacement-password"}'
for initial_running in true false; do
    for initial_enabled in true false; do
        seed_fixture
        SERVICE_RUNNING="$initial_running"
        SERVICE_ENABLED="$initial_enabled"
        save_artifacts
        FAIL_OPERATION=start
        [[ "$initial_running" != true ]] || FAIL_OPERATION=restart
        if _apply_singbox_vless_config "$replacement" replace 46001 ss-legacy; then
            fail 'failed shared service activation committed protocol transaction'
        fi
        # Prove activation was attempted with the replacement before checking rollback.
        assert_json 'any(.singbox["ss-legacy"][]; .port == 46011)' "$TEST_TMP/attempted-db"
        assert_json 'any(.inbounds[]; .listen_port == 46011)' "$TEST_TMP/attempted-config"
        assert_artifacts_restored
        [[ "$SERVICE_RUNNING" == "$initial_running" && "$SERVICE_ENABLED" == "$initial_enabled" ]] || fail 'service state not restored'
    done
done
printf 'ok - protocol activation failures restore DB/config/JOIN/service files, modes and all prior service states\n'

seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=true
cp "$CFG/socks.join" "$TEST_TMP/socks-before"
cp "$CFG/snell-v6.join" "$TEST_TMP/official-before"
_apply_singbox_vless_config '{}' remove 46001 ss-legacy
assert_json '[.inbounds[].listen_port] | sort == [46002,46003]'
assert_json '[.singbox["ss-legacy"][].port] == [46002] and .singbox.socks.port == 46003' "$DB_FILE"
if grep -q '46001' "$CFG/ss-legacy.join" "$CFG/join.txt"; then fail 'removed port survived JOIN regeneration'; fi
grep -q '46002' "$CFG/ss-legacy.join" || fail 'remaining port JOIN missing'
cmp "$TEST_TMP/socks-before" "$CFG/socks.join"
_apply_singbox_vless_config '{}' remove all ss-legacy
assert_json '.inbounds | length == 1 and .[0].type == "socks" and .[0].listen_port == 46003'
assert_json '(.singbox | has("ss-legacy") | not) and .singbox.socks.port == 46003' "$DB_FILE"
[[ ! -e "$CFG/ss-legacy.join" ]] || fail 'removed protocol JOIN retained'
cmp "$TEST_TMP/socks-before" "$CFG/socks.join"
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'retained protocol service stopped/disabled'
[[ -f "$SYSTEMD_DIR/sing-singbox.service" && -f "$OPENRC_DIR/sing-singbox" ]] || fail 'retained protocol lost shared service'
if grep -Eq '^(stop|disable)$' "$TEST_TMP/service-calls"; then fail 'partial removal stopped/disabled shared service'; fi
printf 'ok - removing a port or whole protocol retains other listeners, JOIN files and shared service\n'

: >"$TEST_TMP/service-calls"
_apply_singbox_vless_config '{}' remove all socks
assert_json '.singbox == {} and .snell["snell-v6"].port == 46006' "$DB_FILE"
[[ "$SERVICE_RUNNING" == false && "$SERVICE_ENABLED" == false ]] || fail 'last listener removal left shared service active'
for removed in "$CFG/singbox.json" "$CFG/socks.join" "$SYSTEMD_DIR/sing-singbox.service" "$OPENRC_DIR/sing-singbox"; do
    [[ ! -e "$removed" ]] || fail "last listener removal retained $removed"
done
grep -qx stop "$TEST_TMP/service-calls" || fail 'last removal did not stop shared service'
grep -qx disable "$TEST_TMP/service-calls" || fail 'last removal did not disable shared service'
cmp "$TEST_TMP/official-before" "$CFG/snell-v6.join"
cmp "$TEST_TMP/official-before" "$CFG/join.txt"
grep -qx 'official Snell service sentinel' "$SYSTEMD_DIR/sing-snell-v6.service" || fail 'last shared removal altered official service'
printf 'ok - last shared listener removal stops/disables/deletes shared service and retains official Snell\n'

mock_upgrade_installer() {
    [[ "$*" == 'stable true 1.14.5' ]] || fail "installer arguments: $*"
    write_mock_core 1.14.5
    jq '.log.level = "error"' "$CFG/singbox.json" >"$TEST_TMP/upgraded-config"
    mv "$TEST_TMP/upgraded-config" "$CFG/singbox.json"
    return "$INSTALL_RESULT"
}
write_mock_core() {
    printf '#!/usr/bin/env bash\ncase "$1" in\n version) printf "sing-box version %s\\n" ;;\n check) jq empty "$3" ;;\n *) exit 1 ;;\nesac\n' "$1" >"$CFG/bin/sing-box"
    chmod 755 "$CFG/bin/sing-box"
}
for INSTALL_RESULT in 0 1; do
    seed_fixture
    SERVICE_RUNNING=true
    SERVICE_ENABLED=true
    write_mock_core 1.14.4
    cp -p "$CFG/bin/sing-box" "$TEST_TMP/original-binary"
    save_artifacts
    FAIL_OPERATION=restart
    if _update_singbox_core_to_version stable 1.14.5 mock_upgrade_installer; then
        fail 'failed core upgrade reported success'
    fi
    cmp "$TEST_TMP/original-binary" "$CFG/bin/sing-box"
    [[ -x "$CFG/bin/sing-box" ]] || fail 'restored binary is not executable'
    assert_artifacts_restored
    [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'upgrade rollback did not restore service'
    grep -qx stop "$TEST_TMP/service-calls" || fail 'upgrade rollback did not stop candidate service'
    grep -qx start "$TEST_TMP/service-calls" || fail 'upgrade rollback did not restart original service'
done
printf 'ok - failed activation and partial installer failure restore original core, config and running service\n'
