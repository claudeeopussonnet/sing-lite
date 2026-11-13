#!/usr/bin/env bash
# Exercise public user mutations with real candidate/JOIN generation and mocked runtime only.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { printf '%s\n' "$*" >>"$TEST_TMP/errors"; }
SERVICE_RUNNING=true
SERVICE_ENABLED=true
FAIL_CHECK=false
FAIL_RESTART=false
FAIL_READY=false
FAIL_JOIN=false
EXPECT_LOCK=false
crontab() {
    case "$1" in
        -l) cat "$TEST_TMP/crontab" ;;
        -) cat >"$TEST_TMP/crontab" ;;
        *) forbidden crontab "$@" ;;
    esac
}
xray() {
    [[ "$1 $2 $3 $4 $5" == 'run -test -format json -c' && $# == 6 ]] || forbidden xray "$@"
    if [[ "$EXPECT_LOCK" == true ]]; then
        [[ -n "${DB_LOCK_FD:-}" || "$DB_LOCK_DIR_HELD" == true ]] || fail 'candidate generated without DB lock'
    fi
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
    case "$1" in
        restart|start)
            if [[ "$1" == restart ]]; then
                cp "$DB_FILE" "$TEST_TMP/attempted-db"
                cp "$CFG/xray.json" "$TEST_TMP/attempted-config"
            fi
            if [[ "$1" == restart && "$FAIL_RESTART" == true ]]; then
                FAIL_RESTART=false
                SERVICE_RUNNING=false
                rm -f "$TEST_TMP/runtime.json"
                return 1
            fi
            cp "$CFG/xray.json" "$TEST_TMP/runtime.json"
            SERVICE_RUNNING=true ;;
        stop) SERVICE_RUNNING=false; rm -f "$TEST_TMP/runtime.json" ;;
        *) forbidden svc "$@" ;;
    esac
}
create_xray_service() { forbidden create_xray_service "$@"; }
_wait_for_owned_service() {
    [[ "$1" == sing-xray ]] || forbidden _wait_for_owned_service "$@"
    printf 'ready\n' >>"$TEST_TMP/events"
    if [[ "$FAIL_READY" == true ]]; then FAIL_READY=false; return 1; fi
    [[ "$SERVICE_RUNNING" == true ]]
}
# Fail after the per-protocol JOIN has already changed, exercising partial JOIN rollback.
mv() {
    if [[ "$FAIL_JOIN" == true && "${@: -1}" == "$CFG/join.txt" ]]; then
        FAIL_JOIN=false
        printf 'join-failure\n' >>"$TEST_TMP/events"
        return 1
    fi
    command mv "$@"
}

uuid_default=00000000-0000-4000-8000-000000000001
uuid_other=00000000-0000-4000-8000-000000000002
uuid_new=00000000-0000-4000-8000-000000000003
raw='{"port":48001,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","transport":"raw","sni":"test.example","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","short_id":"00123456","encryption":"none","decryption":"none","routing":"chain:record-route","custom":{"keep":true}}'
refresh_fixture() {
    EXPECT_LOCK=false
    generate_xray_config || fail 'fixture config'
    local protocol
    for protocol in vless vless-xhttp vless-enc; do
        regenerate_xray_protocol_join_info "$protocol" || fail 'fixture JOIN'
    done
    if [[ "$SERVICE_RUNNING" == true ]]; then
        cp "$CFG/xray.json" "$TEST_TMP/runtime.json"
    else
        rm -f "$TEST_TMP/runtime.json"
    fi
    : >"$TEST_TMP/events"
    EXPECT_LOCK=true
}
seed_fixture() {
    TEST_PROTOCOL="${1:-vless}"
    FAIL_CHECK=false
    FAIL_RESTART=false
    FAIL_READY=false
    FAIL_JOIN=false
    SERVICE_RUNNING=true
    SERVICE_ENABLED=true
    rm -f "$CFG"/*.join "$TEST_TMP/attempted-db" "$TEST_TMP/attempted-config"
    jq -n --arg protocol "$TEST_PROTOCOL" --argjson raw "$raw" '
        ($raw | if $protocol == "vless-xhttp" then
            .transport="xhttp" | .xhttp_path="/users" | .xhttp_mode="auto"
        elif $protocol == "vless-enc" then
            .security_mode="encryption" | .encryption="mlkem768x25519plus.native.1rtt.mockClientKey" |
            .decryption="mlkem768x25519plus.native.600s.mockServerKey"
        else . end) as $record |
        {xray:{($protocol):$record},singbox:{socks:{port:48090}},snell:{"snell-v6":{port:48091}},
         routing:{enabled:true,default:"warp",custom:["keep"]},
         ip_routing:{enabled:true,rules:[{inbound_ip:"192.0.2.1",outbound_ip:"192.0.2.2"}]},
         telegram:{chat_id:"fixture-chat"},metadata:{sentinel:"keep"}}
    ' >"$DB_FILE"
    chmod 600 "$DB_FILE"
    printf 'custom role sentinel\n' >"$CFG/role"
    printf 'Sing-box config sentinel\n' >"$CFG/singbox.json"
    printf 'official Snell config sentinel\n' >"$CFG/snell-v6.conf"
    printf 'unrelated JOIN sentinel\n' >"$CFG/socks.join"
    printf 'original systemd unit\n' >"$SYSTEMD_DIR/sing-xray.service"
    printf 'original OpenRC unit\n' >"$OPENRC_DIR/sing-xray"
    chmod 640 "$SYSTEMD_DIR/sing-xray.service"
    chmod 750 "$OPENRC_DIR/sing-xray"
    printf '17 2 * * * true # existing-job\n' >"$TEST_TMP/crontab"
    refresh_fixture
}
artifacts=("$DB_FILE" "$CFG/xray.json" "$CFG/vless.join" "$CFG/vless-xhttp.join" "$CFG/vless-enc.join"
    "$CFG/join.txt" "$CFG/role" "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
    "$CFG/singbox.json" "$CFG/snell-v6.conf" "$CFG/socks.join" "$TEST_TMP/runtime.json" "$TEST_TMP/crontab")
save_artifacts() {
    local file index=0
    rm -rf "$TEST_TMP/expected"
    mkdir "$TEST_TMP/expected"
    for file in "${artifacts[@]}"; do
        [[ ! -f "$file" ]] || cp -p "$file" "$TEST_TMP/expected/$index"
        index=$((index + 1))
    done
    EXPECTED_RUNNING="$SERVICE_RUNNING"
    EXPECTED_ENABLED="$SERVICE_ENABLED"
}
assert_restored() {
    local file index=0
    for file in "${artifacts[@]}"; do
        if [[ -f "$TEST_TMP/expected/$index" ]]; then
            cmp "$TEST_TMP/expected/$index" "$file" || fail "rollback changed $file"
            [[ "$(stat -c %a "$file")" == "$(stat -c %a "$TEST_TMP/expected/$index")" ]] || fail "rollback permissions: $file"
        else
            [[ ! -e "$file" ]] || fail "rollback created $file"
        fi
        index=$((index + 1))
    done
    [[ "$SERVICE_RUNNING" == "$EXPECTED_RUNNING" && "$SERVICE_ENABLED" == "$EXPECTED_ENABLED" ]] || fail 'rollback service state'
    [[ -z "${DB_LOCK_FD:-}" && "$DB_LOCK_DIR_HELD" == false ]] || fail 'leaked DB lock'
}
assert_runtime_update() {
    [[ "$(cat "$TEST_TMP/events")" == $'check\nrestart\nready' ]] || fail 'user mutation runtime operations'
    cmp "$CFG/xray.json" "$TEST_TMP/runtime.json" || fail 'running service did not load new credentials'
    [[ -z "${DB_LOCK_FD:-}" && "$DB_LOCK_DIR_HELD" == false ]] || fail 'successful mutation leaked DB lock'
    assert_json '.routing == null and .outbounds == [{protocol:"freedom",tag:"direct"}]' "$CFG/xray.json"
    grep -qx 'custom role sentinel' "$CFG/role" || fail 'user mutation changed role'
    grep -qx 'unrelated JOIN sentinel' "$CFG/join.txt" || fail 'aggregate JOIN lost unrelated protocol'
    [[ "$(stat -c %a "$DB_FILE")" == 600 && "$(stat -c %a "$CFG/xray.json")" == 600 ]] || fail 'candidate permissions'
    : >"$TEST_TMP/events"
}

for protocol in vless vless-xhttp vless-enc; do
    seed_fixture "$protocol"
    SERVICE_ENABLED=false
    db_set_user_enabled xray "$protocol" default true || fail 'legacy default initial enable failed'
    assert_json ".xray[\"$protocol\"].users == [{name:\"default\",uuid:\"$uuid_default\",enabled:true}]" "$DB_FILE"
    assert_runtime_update
    db_set_user_enabled xray "$protocol" default false || fail 'legacy default disable failed'
    assert_json ".xray[\"$protocol\"].users[0].enabled == false" "$DB_FILE"
    assert_json '.inbounds == []' "$CFG/xray.json"
    [[ ! -e "$CFG/$protocol.join" ]] || fail 'disabled default retained JOIN'
    assert_runtime_update
    db_set_user_enabled xray "$protocol" default true || fail 'legacy default reenable failed'
    assert_json ".inbounds[0].settings.clients[0].id == \"$uuid_default\"" "$TEST_TMP/runtime.json"
    [[ -s "$CFG/$protocol.join" && "$SERVICE_ENABLED" == false ]] || fail 'reenable JOIN/service state'
    assert_runtime_update
done
printf 'ok - all Xray protocols normalize legacy defaults and enable/disable/enable immediately\n'

seed_fixture
save_artifacts
FAIL_RESTART=true
if db_set_user_enabled xray vless default false; then fail 'failed legacy disable committed normalization'; fi
assert_restored
assert_json '.xray.vless | has("users") | not' "$DB_FILE"
: >"$TEST_TMP/events"
db_del_user xray vless default || fail 'fresh legacy default removal failed'
assert_json '.xray.vless.users == []' "$DB_FILE"
assert_json '.inbounds == []' "$CFG/xray.json"
[[ ! -e "$CFG/vless.join" ]] || fail 'fresh default removal restored fallback JOIN'
assert_runtime_update
printf 'ok - failed legacy normalization restores original bytes and direct legacy removal never falls back\n'

seed_fixture
SERVICE_ENABLED=false
db_add_user xray vless bob "$uuid_new" || fail 'public add returned failure'
assert_json ".xray.vless.users | map(.name) == [\"default\",\"bob\"]" "$DB_FILE"
assert_json ".inbounds[0].settings.clients | map(.id) == [\"$uuid_default\",\"$uuid_new\"]" "$CFG/xray.json"
assert_json ".xray.vless.users[1] | .enabled == true and .created == \"$(date '+%Y-%m-%d')\" and .expire_date == \"\"" "$DB_FILE"
grep -q "$uuid_new" "$CFG/vless.join" || fail 'added user missing JOIN'
assert_runtime_update
db_del_user xray vless bob || fail 'public remove returned failure'
assert_json ".inbounds[0].settings.clients | map(.id) == [\"$uuid_default\"]" "$CFG/xray.json"
if grep -q "$uuid_new" "$CFG/join.txt"; then fail 'removed user remained in JOIN'; fi
assert_runtime_update
db_add_user xray vless dated "$uuid_new" 2000-01-01 >/dev/null || fail 'cron installation changed successful add status'
grep -q 'check-expire' "$TEST_TMP/crontab" || fail 'expiring add did not install isolated cron'
grep -q 'existing-job' "$TEST_TMP/crontab" || fail 'expiring add overwrote cron'
assert_runtime_update
assert_json '.routing.default == "warp" and .ip_routing.rules[0].outbound_ip == "192.0.2.2" and
    .metadata.sentinel == "keep" and .xray.vless.routing == "chain:record-route" and .xray.vless.custom.keep' "$DB_FILE"
printf 'ok - public add/remove return success and update runtime/JOIN, retaining legacy credentials and routing metadata\n'

seed_fixture
rewrite_db '.xray.vless = [.xray.vless,
    (.xray.vless | .port=48002 | .users=[{name:"default",uuid:"00000000-0000-4000-8000-000000000002",enabled:true,
        created:"2020-01-01",expire_date:"2099-01-01",routing:"warp",telegram_chat_id:"fixture-chat",
        telegram_username:"fixture-user",telegram_bound_at:"fixture-time",custom:{keep:true}}]),
    (.xray.vless | .port=48003 | .users=[]),
    (.xray.vless | .port=48004 | .users=[{name:"disabled",uuid:"00000000-0000-4000-8000-000000000004",enabled:false}])] |
    .xray["vless-xhttp"]=(.xray.vless[0] | .port=48005 | .transport="xhttp" | .xhttp_path="/other")'
refresh_fixture
jq -S '.xray.vless[1].users[0] | del(.enabled)' "$DB_FILE" >"$TEST_TMP/metadata-before"
db_add_user xray vless bob "$uuid_new" || fail 'multiport add'
assert_json '[.xray.vless[].users | map(.name)] == [["default","bob"],["default"],[],["disabled"]]' "$DB_FILE"
assert_runtime_update
db_set_user_enabled xray vless default false || fail 'multiport disable'
assert_json '[.xray.vless[].users[] | select(.name == "default") | .enabled] == [false,false]' "$DB_FILE"
assert_json '[.inbounds[].port] == [48001,48005]' "$CFG/xray.json"
assert_runtime_update
jq -S '.xray.vless[1].users[0] | del(.enabled)' "$DB_FILE" >"$TEST_TMP/metadata-after"
cmp "$TEST_TMP/metadata-before" "$TEST_TMP/metadata-after" || fail 'enable mutation lost Telegram/routing/expiry metadata'
db_set_user_enabled xray vless default true || fail 'multiport enable'
assert_json '[.inbounds[].port] == [48001,48002,48005]' "$CFG/xray.json"
assert_runtime_update
db_del_user xray vless default || fail 'multiport remove'
assert_json '[.xray.vless[].users | map(.name)] == [["bob"],[],[],["disabled"]]' "$DB_FILE"
assert_runtime_update
db_del_user xray vless bob || fail 'remove final enabled user'
assert_json '[.inbounds[].port] == [48005]' "$CFG/xray.json"
[[ ! -e "$CFG/vless.join" && -s "$CFG/vless-xhttp.join" ]] || fail 'empty users fell back to record credentials'
assert_json '.xray.vless | length == 4' "$DB_FILE"
assert_runtime_update
printf 'ok - multiport mutations target every match, add only to first port and preserve metadata/empty/disabled lists\n'

for initial_enabled in true false; do
    for units in present absent; do
        seed_fixture
        SERVICE_RUNNING=false
        SERVICE_ENABLED="$initial_enabled"
        [[ "$units" == present ]] || rm -f "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
        refresh_fixture
        XRAY_ACTIVATE_SERVICE=true
        db_set_user_enabled xray vless default false || fail 'stopped disable'
        db_add_user xray vless bob "$uuid_new" || fail 'stopped add'
        db_del_user xray vless bob || fail 'stopped remove'
        db_set_user_enabled xray vless default true || fail 'stopped reenable'
        unset XRAY_ACTIVATE_SERVICE
        [[ "$(cat "$TEST_TMP/events")" == $'check\ncheck\ncheck\ncheck' ]] || fail 'stopped user mutation activated service'
        [[ "$SERVICE_RUNNING" == false && "$SERVICE_ENABLED" == "$initial_enabled" ]] || fail 'stopped service state changed'
        if [[ "$units" == absent ]]; then
            [[ ! -e "$SYSTEMD_DIR/sing-xray.service" && ! -e "$OPENRC_DIR/sing-xray" ]] || fail 'stopped mutation created units'
        else
            grep -qx 'original systemd unit' "$SYSTEMD_DIR/sing-xray.service" || fail 'stopped mutation rewrote unit'
        fi
        assert_json ".inbounds[0].settings.clients[0].id == \"$uuid_default\"" "$CFG/xray.json"
        [[ ! -e "$TEST_TMP/runtime.json" && -s "$CFG/vless.join" ]] || fail 'stopped config/JOIN update'
    done
done
printf 'ok - stopped services stay stopped for all user operations, enabled states and missing units\n'

mutate_user() {
    case "$mutation" in
        add) db_add_user xray vless bob "$uuid_new" 2099-01-01 ;;
        remove) db_del_user xray vless alice ;;
        enabled) db_set_user_enabled xray vless alice false ;;
    esac
}
for mutation in add remove enabled; do
    for initial_enabled in true false; do
        for initial_running in true false; do
            for failure in check restart ready join; do
                [[ "$initial_running" == true || ( "$failure" != restart && "$failure" != ready ) ]] || continue
                seed_fixture
                rewrite_db '.xray.vless.users=[{name:"alice",uuid:"00000000-0000-4000-8000-000000000001",enabled:true,
                    expire_date:"2000-01-01",telegram_chat_id:"fixture-chat",routing:"warp"},
                    {name:"other",uuid:"00000000-0000-4000-8000-000000000002",enabled:true}]'
                SERVICE_ENABLED="$initial_enabled"
                SERVICE_RUNNING="$initial_running"
                if [[ "$initial_running" == false && "$initial_enabled" == false ]]; then
                    rm -f "$SYSTEMD_DIR/sing-xray.service" "$OPENRC_DIR/sing-xray"
                fi
                refresh_fixture
                save_artifacts
                case "$failure" in
                    check) FAIL_CHECK=true ;;
                    restart) FAIL_RESTART=true ;;
                    ready) FAIL_READY=true ;;
                    join) FAIL_JOIN=true ;;
                esac
                if mutate_user >"$TEST_TMP/mutation-output"; then fail "$mutation $failure committed"; fi
                assert_restored
                if [[ "$failure" == check ]]; then
                    [[ "$(cat "$TEST_TMP/events")" == check ]] || fail 'validation failure touched service'
                elif [[ "$failure" == join ]]; then
                    [[ "$(cat "$TEST_TMP/events")" == $'check\njoin-failure' ]] || fail 'JOIN failure touched service'
                else
                    [[ "$(head -n 2 "$TEST_TMP/events")" == $'check\nrestart' ]] || fail 'service activation preceded check'
                    case "$mutation" in
                        add)
                            assert_json 'any(.xray.vless.users[]; .name == "bob")' "$TEST_TMP/attempted-db"
                            assert_json 'any(.inbounds[].settings.clients[]; .email == "bob")' "$TEST_TMP/attempted-config" ;;
                        remove|enabled)
                            assert_json 'all(.xray.vless.users[]; .name != "alice" or .enabled == false)' "$TEST_TMP/attempted-db"
                            assert_json 'all(.inbounds[].settings.clients[]; .email != "alice")' "$TEST_TMP/attempted-config" ;;
                    esac
                fi
                [[ -z "$(find "$CFG" -maxdepth 1 -name '.xray-config.*' -print)" ]] || fail 'successful restoration leaked snapshot'
            done
        done
    done
done
printf 'ok - add/remove/enable failures restore DB/config/JOIN/units/runtime bytes and modes across service states\n'

seed_fixture
db_add_user xray vless expired "$uuid_new" 2000-01-01 >/dev/null || fail 'expired fixture add'
: >"$TEST_TMP/events"
save_artifacts
FAIL_RESTART=true
if db_set_user_enabled xray vless expired false; then fail 'failed expiry disable committed'; fi
assert_restored
assert_json '.xray.vless.users[] | select(.name == "expired") | .enabled == true' "$DB_FILE"
db_get_expired_users >"$TEST_TMP/expired-candidates" || true
grep -q '^xray|vless|expired|2000-01-01|' "$TEST_TMP/expired-candidates" || fail 'failed expiry disable lost retry candidate'
: >"$TEST_TMP/events"
db_set_user_enabled xray vless expired false || fail 'expiry retry failed'
assert_runtime_update
db_get_expired_users >"$TEST_TMP/expired-candidates" || true
[[ ! -s "$TEST_TMP/expired-candidates" ]] || fail 'successful expiry retry stayed eligible'
printf 'ok - failed expiry disable keeps account enabled and eligible for a successful retry\n'

seed_fixture
rewrite_db '.xray.vless=[.xray.vless,(.xray.vless | .port=48002 | .users=[{name:"second",uuid:"00000000-0000-4000-8000-000000000002",enabled:true}])]'
refresh_fixture
save_artifacts
if db_add_user xray vless second "$uuid_new"; then fail 'duplicate on second port accepted'; fi
if db_add_user xray vless default "$uuid_new"; then fail 'duplicate legacy default accepted'; fi
if db_del_user xray vless missing; then fail 'missing removal target accepted'; fi
if db_set_user_enabled xray vless missing false; then fail 'missing enable target accepted'; fi
if db_set_user_enabled xray vless default invalid; then fail 'invalid enabled accepted'; fi
if db_del_user xray vless-enc missing; then fail 'missing protocol accepted'; fi
[[ ! -s "$TEST_TMP/events" ]] || fail 'duplicate/missing/invalid target reached validation or service mutation'
assert_restored
printf 'ok - duplicate names across ports, legacy duplicates and absent targets reject before candidate validation/service changes\n'

# A writer can win the lock after public preflight; duplicate validation must see its record.
_db_lock_acquire() {
    [[ -z "${DB_LOCK_FD:-}" ]] || fail 'nested DB lock'
    exec {DB_LOCK_FD}>"$DB_LOCK_FILE" || return 1
    flock -x "$DB_LOCK_FD" || return 1
    rewrite_db '.xray.vless[1].users += [{name:"raced",uuid:"00000000-0000-4000-8000-000000000004",enabled:true}]'
    save_artifacts
}
if db_add_user xray vless raced "$uuid_new"; then fail 'duplicate lock winner overwritten'; fi
[[ ! -s "$TEST_TMP/events" ]] || fail 'lock-time duplicate reached validator/runtime'
assert_restored
printf 'ok - duplicate validation runs against the DB acquired under lock\n'
