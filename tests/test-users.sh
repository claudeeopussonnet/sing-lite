#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
init_db
db_add singbox vless-ws-notls '{"port":45001,"uuid":"00000000-0000-4000-8000-000000000001","path":"/test","users":[{"name":"alice","uuid":"00000000-0000-4000-8000-000000000002","enabled":true,"routing":"direct"},{"name":"bob","uuid":"00000000-0000-4000-8000-000000000003","enabled":false,"routing":"direct"}]}'
# Exercise the actual DB update and generation while replacing service reloads.
rebuild_and_reload_singbox() {
    printf 'reload\n' >>"$TEST_TMP/reloads"
    generate_singbox_config
}
generate_singbox_config
[[ "$(db_get_user_field singbox vless-ws-notls bob enabled)" == false ]] || fail 'false DB field was collapsed to empty'
assert_json '.inbounds[0].users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000002"'
assert_json 'all(.route.rules[] | .auth_user[]?; contains("bob") | not)'
db_set_user_enabled singbox vless-ws-notls alice false
[[ "$(db_get_user_field singbox vless-ws-notls alice enabled)" == false ]] || fail 'disabled flag readback'
assert_json '.inbounds[0].users == []'
assert_json '[.route.rules[] | .auth_user[]?] == []'
db_set_user_enabled singbox vless-ws-notls bob true
assert_json '.inbounds[0].users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000003"'
printf 'ok - boolean false survives DB reads and disable/enable rebuilds credentials and routes\n'

rewrite_db '.singbox["vless-ws-notls"] as $first | .singbox["vless-ws-notls"] = [$first, ($first | .port=45002)]'
db_set_user_enabled singbox vless-ws-notls bob false
assert_json '.inbounds | length == 2 and all(.[]; .users == [])'
assert_json 'all(.singbox["vless-ws-notls"][].users[] | select(.name == "bob"); .enabled == false)' "$DB_FILE"
[[ "$(db_get_user_field singbox vless-ws-notls bob enabled)" == false ]] || fail 'multiport false DB field'
db_set_user_enabled singbox vless-ws-notls alice true
assert_json '.inbounds | length == 2 and all(.[]; .users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000002")'
[[ "$(wc -l <"$TEST_TMP/reloads")" == 4 ]] || fail 'user mutation did not rebuild exactly once'
printf 'ok - multiport disable/enable updates every listener without restoring legacy credentials\n'
