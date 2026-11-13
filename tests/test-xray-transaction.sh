#!/usr/bin/env bash
# Real Xray mutations and rollback, with temporary files and mocked services only.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { printf '%s\n' "$*" >>"$TEST_TMP/errors"; }
SERVICE_RUNNING=false
SERVICE_ENABLED=false
FAIL_OPERATION=''
FAIL_CHECK=false
FAIL_READY=false
FAIL_CREATE=false
xray() {
    [[ "$1 $2 $3 $4 $5" == 'run -test -format json -c' && $# == 6 ]] || forbidden xray "$@"
    printf 'check\n' >>"$TEST_TMP/events"
    jq empty "$6" && [[ "$FAIL_CHECK" != true ]]
}
svc() {
    [[ "$2" == sing-xray ]] || forbidden svc "$@"
    case "$1" in
        status) [[ "$SERVICE_RUNNING" == true ]]; return ;;
        enabled) [[ "$SERVICE_ENABLED" == true ]]; return ;;
    esac
    printf '%s\n' "$1" >>"$TEST_TMP/events"
    if [[ "$FAIL_OPERATION" == "$1" ]]; then
        FAIL_OPERATION=''
        if [[ "$1" == start || "$1" == restart ]]; then
            SERVICE_RUNNING=false
            cp "$DB_FILE" "$TEST_TMP/attempted-db"
            cp "$CFG/xray.json" "$TEST_TMP/attempted-config"
        elif [[ "$1" == enable ]]; then
            # Enabling can create symlinks before reporting an error.
            SERVICE_ENABLED=true
        fi
        return 1
    fi
    case "$1" in
        enable) SERVICE_ENABLED=true ;;
        disable) SERVICE_ENABLED=false ;;
        stop) SERVICE_RUNNING=false ;;
        start|restart)
            [[ -f "$SYSTEMD_DIR/sing-xray.service" || -f "$OPENRC_DIR/sing-xray" ]] || fail 'activation without unit'
            SERVICE_RUNNING=true ;;
        *) forbidden svc "$@" ;;
    esac
}
systemctl() {
    [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"
    printf 'daemon-reload\n' >>"$TEST_TMP/events"
}
create_xray_service() {
    printf 'create\n' >>"$TEST_TMP/events"
    printf 'candidate systemd service\n' >"$SYSTEMD_DIR/sing-xray.service"
    printf 'candidate OpenRC service\n' >"$OPENRC_DIR/sing-xray"
    [[ "$FAIL_CREATE" != true ]]
}
_wait_for_owned_service() {
    [[ "$1" == sing-xray ]] || forbidden _wait_for_owned_service "$@"
    printf 'ready\n' >>"$TEST_TMP/events"
    if [[ "$FAIL_READY" == true ]]; then FAIL_READY=false; return 1; fi
    [[ "$SERVICE_RUNNING" == true ]]
}
raw='{"port":48001,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","transport":"raw","sni":"test.example","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","short_id":"00123456","encryption":"none","decryption":"none"}'
seed_fixture() {
    FAIL_OPERATION=''
    FAIL_CHECK=false
    FAIL_READY=false
    FAIL_CREATE=false
    rm -f "$CFG"/*.join "$CFG/xray.json" "$CFG/role" "$TEST_TMP/attempted-db" "$TEST_TMP/attempted-config"
    mkdir -p "$CFG/bin"
    printf 'owned binary sentinel\n' >"$CFG/bin/xray"
    jq -n --argjson raw "$raw" '
        {singbox:{socks:{port:48090}},snell:{"snell-v6":{port:48091}},xray:{
            vless:[$raw,($raw | .port=48002)],
            "vless-xhttp":($raw | .port=48003 | .transport="xhttp" | .xhttp_path="/test" | .xhttp_mode="auto" |
                .users=[{name:"alice",uuid:"00000000-0000-4000-8000-000000000002",enabled:true},
                        {name:"disabled",uuid:"00000000-0000-4000-8000-000000000003",enabled:false}])}}
    ' >"$DB_FILE"
    chmod 600 "$DB_FILE"
    generate_xray_config
    printf 'Sing-box JOIN sentinel\n' >"$CFG/socks.join"
    printf 'official Snell JOIN sentinel\n' >"$CFG/snell-v6.join"
    printf 'Sing-box config sentinel\n' >"$CFG/singbox.json"
    printf 'official Snell config sentinel\n' >"$CFG/snell-v6.conf"
    printf 'official service sentinel\n' >"$SYSTEMD_DIR/sing-snell-v6.service"
    regenerate_xray_protocol_join_info vless
    regenerate_xray_protocol_join_info vless-xhttp
    printf 'server\n' >"$CFG/role"
    printf 'original systemd service\n' >"$SYSTEMD_DIR/sing-xray.service"
    printf 'original OpenRC service\n' >"$OPENRC_DIR/sing-xray"
    chmod 640 "$SYSTEMD_DIR/sing-xray.service"
    chmod 750 "$OPENRC_DIR/sing-xray"
    : >"$TEST_TMP/events"
}
artifacts=("$DB_FILE" "$CFG/xray.json" "$CFG/vless.join" "$CFG/vless-xhttp.join" "$CFG/vless-enc.join"
    "$CFG/join.txt" "$CFG/role" "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
    "$CFG/socks.join" "$CFG/snell-v6.join" "$CFG/singbox.json" "$CFG/snell-v6.conf"
    "$SYSTEMD_DIR/sing-snell-v6.service" "$CFG/bin/xray")
save_artifacts() {
    local file index=0
    rm -rf "$TEST_TMP/expected"
    mkdir "$TEST_TMP/expected"
    for file in "${artifacts[@]}"; do
        [[ ! -f "$file" ]] || cp -p "$file" "$TEST_TMP/expected/$index"
        index=$((index + 1))
    done
}
assert_restored() {
    local file index=0
    for file in "${artifacts[@]}"; do
        if [[ -f "$TEST_TMP/expected/$index" ]]; then
            cmp "$TEST_TMP/expected/$index" "$file" || fail "rollback changed $file"
            [[ "$(stat -c %a "$file")" == "$(stat -c %a "$TEST_TMP/expected/$index")" ]] || fail "rollback permissions: $file"
        else
            [[ ! -e "$file" ]] || fail "rollback left newly created artifact: $file"
        fi
        index=$((index + 1))
    done
}
replacement=$(jq '.port=48011' <<<"$raw")
for initial_running in true false; do
    for initial_enabled in true false; do
        seed_fixture
        SERVICE_RUNNING="$initial_running"
        SERVICE_ENABLED="$initial_enabled"
        save_artifacts
        FAIL_OPERATION=start
        [[ "$initial_running" != true ]] || FAIL_OPERATION=restart
        if _apply_xray_config "$replacement" replace 48001 vless; then fail 'failed activation committed'; fi
        assert_json 'any(.xray.vless[]; .port == 48011)' "$TEST_TMP/attempted-db"
        assert_json 'any(.inbounds[]; .port == 48011)' "$TEST_TMP/attempted-config"
        assert_restored
        [[ "$SERVICE_RUNNING" == "$initial_running" && "$SERVICE_ENABLED" == "$initial_enabled" ]] || fail 'service state rollback'
    done
done
printf 'ok - activation failures restore DB/config/JOIN/unit contents and modes for all service states\n'

seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=true
save_artifacts
for port in 48001 48002 48003 48090 48091; do
    duplicate=$(jq --argjson port "$port" '.port=$port' <<<"$raw")
    : >"$TEST_TMP/events"
    if _apply_xray_config "$duplicate" add '' vless; then fail 'duplicate add succeeded'; fi
    [[ ! -s "$TEST_TMP/events" ]] || fail 'duplicate add invoked validation or service operation'
    assert_restored
done
duplicate=$(jq '.port=48003' <<<"$raw")
if _apply_xray_config "$duplicate" replace 48001 vless; then fail 'duplicate replacement succeeded'; fi
if _apply_xray_config "$replacement" replace 48999 vless; then fail 'missing replacement target succeeded'; fi
FAIL_CHECK=true
if _apply_xray_config "$replacement" replace 48001 vless; then fail 'failed check committed'; fi
FAIL_CHECK=false
[[ "$(cat "$TEST_TMP/events")" == check ]] || fail 'failed check touched service'
assert_restored
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'validation disturbed service state'
printf 'ok - duplicate ports in every core, missing targets and failed checks never restart the service\n'

for failure in enable create ready; do
    seed_fixture
    SERVICE_RUNNING=true
    SERVICE_ENABLED=false
    save_artifacts
    case "$failure" in enable) FAIL_OPERATION=enable ;; create) FAIL_CREATE=true ;; ready) FAIL_READY=true ;; esac
    if _apply_xray_config "$replacement" replace 48001 vless; then fail "$failure failure committed"; fi
    assert_restored
    [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == false ]] || fail "$failure state rollback"
done
printf 'ok - service creation, enable and readiness failures roll back all Xray artifacts\n'

seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=true
save_artifacts
base64() { return 1; }
if _apply_xray_config "$replacement" replace 48001 vless; then fail 'JOIN write failure committed'; fi
unset -f base64
assert_restored
[[ "$(cat "$TEST_TMP/events")" == check ]] || fail 'JOIN failure touched service'
(
    : >"$TEST_TMP/events"
    get_connection_addresses() { return 1; }
    if _apply_xray_config "$replacement" replace 48001 vless; then fail 'JOIN address lookup failure committed'; fi
    assert_restored
    [[ "$(cat "$TEST_TMP/events")" == check ]] || fail 'JOIN address lookup failure touched service'
)
printf 'ok - JOIN failure restores committed DB/config before any service operation\n'

seed_fixture
rewrite_db '.xray={}'
rm -f "$CFG/xray.json" "$CFG/vless.join" "$CFG/vless-xhttp.join" "$CFG/role" \
    "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
regenerate_xray_protocol_join_info vless
SERVICE_RUNNING=false
SERVICE_ENABLED=false
save_artifacts
FAIL_OPERATION=start
if _apply_xray_config "$raw" add '' vless; then fail 'failed first install committed'; fi
assert_restored
[[ "$SERVICE_RUNNING" == false && "$SERVICE_ENABLED" == false ]] || fail 'first install rollback state'
_apply_xray_config "$raw" add '' vless
assert_json '.xray.vless | length == 1 and .[0].port == 48001' "$DB_FILE"
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true && -s "$CFG/vless.join" ]] || fail 'first install activation'
printf 'ok - first installation activates service and failed installation removes newly created artifacts\n'

seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=true
# Replacing one listener preserves its explicit users when the new record omits them.
rewrite_db '.xray.vless[0].users=[{name:"kept",uuid:"00000000-0000-4000-8000-000000000008",enabled:true}]'
_apply_xray_config "$replacement" replace 48001 vless
assert_json '.xray.vless | length == 2 and .[0].port == 48011 and .[0].users[0].name == "kept" and .[1].port == 48002' "$DB_FILE"
assert_json '.inbounds[] | select(.port == 48011) | .settings.clients[0].id == "00000000-0000-4000-8000-000000000008"' "$CFG/xray.json"
encryption_record='{"port":48004,"uuid":"00000000-0000-4000-8000-000000000004","transport":"raw","security_mode":"encryption","encryption":"mlkem768x25519plus.native.1rtt.mockClientKey","decryption":"mlkem768x25519plus.native.600s.mockServerKey"}'
: >"$TEST_TMP/events"
_apply_xray_config "$encryption_record" add '' vless-enc
[[ "$(head -n 1 "$TEST_TMP/events")" == check ]] || fail 'activation preceded candidate validation'
assert_json '.inbounds[] | select(.port == 48004) | .settings.decryption == "mlkem768x25519plus.native.600s.mockServerKey"' "$CFG/xray.json"
grep -q 'mockClientKey' "$CFG/vless-enc.join" || fail 'client encryption missing from JOIN'
[[ "$(grep -c '^VLESS_XHTTP_' "$CFG/vless-xhttp.join")" == 2 ]] || fail 'enabled user JOIN address count'
if grep -q '00000000-0000-4000-8000-000000000003' "$CFG/vless-xhttp.join"; then fail 'disabled user JOIN'; fi
if grep -q 'eCtXsJZ27\|mockServerKey\|private_key\|decryption' "$CFG"/*.join "$CFG/join.txt"; then fail 'server secret in JOIN'; fi
for file in "$CFG"/vless*.join "$CFG/join.txt"; do [[ "$(stat -c %a "$file")" == 600 ]] || fail 'JOIN permissions'; done
while IFS= read -r encoded; do
    decoded=$(printf '%s' "${encoded#*=}" | base64 -d)
    [[ "$decoded" == vless://* && "$decoded" != *mockServerKey* && "$decoded" != *eCtXsJZ27* ]] || fail 'JOIN code contains server credentials'
done < <(grep '^JOIN_' "$CFG/join.txt")
_apply_xray_config '{}' remove all vless-enc
_apply_xray_config '{}' remove 48011 vless
assert_json '[.xray.vless[].port] == [48002]' "$DB_FILE"
_apply_xray_config '{}' remove all vless
assert_json '(.xray | has("vless") | not) and .xray["vless-xhttp"].port == 48003' "$DB_FILE"
[[ ! -e "$CFG/vless.join" && -s "$CFG/vless-xhttp.join" ]] || fail 'partial removal JOIN state'
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'partial removal service state'
if grep -Eq '^(stop|disable)$' "$TEST_TMP/events"; then fail 'partial removal stopped service'; fi
_apply_xray_config '{}' remove all vless-xhttp
assert_json '.xray == {} and .singbox.socks.port == 48090 and .snell["snell-v6"].port == 48091' "$DB_FILE"
[[ "$SERVICE_RUNNING" == false && "$SERVICE_ENABLED" == false ]] || fail 'last removal service state'
for file in "$CFG/xray.json" "$CFG/vless-xhttp.join" "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"; do
    [[ ! -e "$file" ]] || fail "last removal retained $file"
done
[[ -f "$CFG/bin/xray" ]] || fail 'last removal deleted binary'
grep -qx 'Sing-box JOIN sentinel' "$CFG/join.txt" || fail 'unrelated aggregate JOIN lost'
grep -qx 'official Snell JOIN sentinel' "$CFG/join.txt" || fail 'official aggregate JOIN lost'
printf 'ok - replacements retain users, multiport JOINs filter enabled accounts and last removal retains other cores and binary\n'

for failure in stop disable; do
    seed_fixture
    SERVICE_RUNNING=true
    SERVICE_ENABLED=true
    _apply_xray_config '{}' remove all vless
    save_artifacts
    FAIL_OPERATION="$failure"
    if _apply_xray_config '{}' remove all vless-xhttp; then fail "last removal $failure failure committed"; fi
    assert_restored
    [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'last removal rollback state'
done
printf 'ok - failed final stop/disable restores listeners, units and service state\n'

seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=true
rewrite_db '.xray.vless |= map(.users=[]) | .xray["vless-xhttp"].users |= map(.enabled=false)'
rebuild_and_reload_xray
assert_json '.inbounds == []' "$CFG/xray.json"
[[ ! -e "$CFG/vless.join" && ! -e "$CFG/vless-xhttp.join" ]] || fail 'rebuild kept disabled JOIN'
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'empty-account rebuild state'
save_artifacts
rewrite_db '.xray.vless[1].users=[{name:"new",uuid:"00000000-0000-4000-8000-000000000009"}]'
cp -p "$DB_FILE" "$TEST_TMP/expected/0"
FAIL_OPERATION=restart
if rebuild_and_reload_xray; then fail 'failed runtime reload committed config'; fi
assert_restored
[[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'runtime reload state rollback'
SERVICE_RUNNING=false
: >"$TEST_TMP/events"
rebuild_and_reload_xray
[[ "$(cat "$TEST_TMP/events")" == check && "$SERVICE_RUNNING" == false ]] || fail 'stopped reload activated service'
[[ -s "$CFG/vless.join" ]] || fail 'reload failed to rebuild all installed keys'
SERVICE_RUNNING=true
rewrite_db '.xray={}'
: >"$TEST_TMP/events"
rebuild_and_reload_xray
assert_json '.inbounds == []' "$CFG/xray.json"
grep -qx restart "$TEST_TMP/events" || fail 'empty namespace rebuild left stale runtime listeners'
printf 'ok - user rebuild filters all keys, keeps stopped service stopped and rolls back failed runtime activation\n'

# Global start explicitly creates/enables/activates Xray inside the same transaction.
for initial_running in true false; do
    for initial_enabled in true false; do
        seed_fixture
        SERVICE_RUNNING="$initial_running"
        SERVICE_ENABLED="$initial_enabled"
        cp -p "$DB_FILE" "$TEST_TMP/start-db"
        rebuild_and_reload_xray start
        cmp "$TEST_TMP/start-db" "$DB_FILE" || fail 'explicit start rewrote DB'
        [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'explicit start did not activate/enable'
        [[ "$(head -n 1 "$TEST_TMP/events")" == check ]] || fail 'explicit start activated before validation'
        grep -qx create "$TEST_TMP/events" || fail 'explicit start did not create service'
        operation=start
        [[ "$initial_running" != true ]] || operation=restart
        grep -qx "$operation" "$TEST_TMP/events" || fail "explicit start omitted $operation"
        grep -qx ready "$TEST_TMP/events" || fail 'explicit start omitted readiness'
        [[ -z "${XRAY_ACTIVATE_SERVICE+x}" ]] || fail 'activation flag leaked'
    done
done
SERVICE_RUNNING=false
: >"$TEST_TMP/events"
rebuild_and_reload_xray silent
[[ "$(cat "$TEST_TMP/events")" == check && "$SERVICE_RUNNING" == false ]] || fail 'start mode leaked into default rebuild'
printf 'ok - explicit start creates/enables/starts or restarts and default rebuild still preserves stopped state\n'

for initial_running in true false; do
    for initial_enabled in true false; do
        for failure in check create enable runtime ready; do
            seed_fixture
            SERVICE_RUNNING="$initial_running"
            SERVICE_ENABLED="$initial_enabled"
            if [[ "$initial_running" == false && "$initial_enabled" == false ]]; then
                rm -f "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
            fi
            save_artifacts
            case "$failure" in
                check) FAIL_CHECK=true ;;
                create) FAIL_CREATE=true ;;
                enable) FAIL_OPERATION=enable ;;
                runtime)
                    FAIL_OPERATION=start
                    [[ "$initial_running" != true ]] || FAIL_OPERATION=restart ;;
                ready) FAIL_READY=true ;;
            esac
            if rebuild_and_reload_xray start; then fail "explicit start $failure failure committed"; fi
            assert_restored
            [[ "$SERVICE_RUNNING" == "$initial_running" && "$SERVICE_ENABLED" == "$initial_enabled" ]] || fail "explicit start $failure state rollback"
            [[ -z "${XRAY_ACTIVATE_SERVICE+x}" && -z "${DB_LOCK_FD:-}" ]] || fail 'failed explicit start leaked flag/lock'
            if [[ "$failure" == check ]]; then
                [[ "$(cat "$TEST_TMP/events")" == check ]] || fail 'rejected start candidate touched service'
            fi
        done
    done
done
printf 'ok - explicit start validation/service-file/enable/runtime/readiness failures restore all files and prior service states\n'

# Restore failures retain a private snapshot rather than deleting the only recovery copy.
seed_fixture
SERVICE_RUNNING=true
SERVICE_ENABLED=false
FAIL_OPERATION=restart
cp() {
    if [[ "$1" == -p && "$2" == "$CFG"/.xray-config.*/0 ]]; then return 1; fi
    command cp "$@"
}
if _apply_xray_config "$replacement" replace 48001 vless; then fail 'restore failure reported success'; fi
unset -f cp
snapshots=("$CFG"/.xray-config.*)
[[ ${#snapshots[@]} == 1 && -f "${snapshots[0]}/0" && -f "${snapshots[0]}/1" ]] || fail 'restore failure discarded snapshot'
[[ "$(stat -c %a "${snapshots[0]}")" == 700 ]] || fail 'snapshot permissions'
grep -q '快照保留' "$TEST_TMP/errors" || fail 'restore failure omitted recovery location'
[[ -z "${DB_LOCK_FD:-}" ]] || fail 'failed transaction retained DB lock'
printf 'ok - failed restoration preserves private snapshots and releases DB lock\n'
