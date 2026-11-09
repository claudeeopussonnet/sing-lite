#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
init_db
db_add singbox vless-singbox '{"port":45001,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","sni":"test.example","short_id":"00123456","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","users":[{"name":"alice","uuid":"00000000-0000-4000-8000-000000000002","enabled":true,"routing":"direct"},{"name":"bob","uuid":"00000000-0000-4000-8000-000000000003","enabled":false,"routing":"direct"}]}'
# Exercise the actual DB update and generation while replacing service reloads.
rebuild_and_reload_singbox() {
    printf 'reload\n' >>"$TEST_TMP/reloads"
    generate_singbox_config
}
generate_singbox_config
[[ "$(db_get_user_field singbox vless-singbox bob enabled)" == false ]] || fail 'false DB field was collapsed to empty'
assert_json '.inbounds[0].users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000002"'
assert_json 'all(.route.rules[] | .auth_user[]?; contains("bob") | not)'
db_set_user_enabled singbox vless-singbox alice false
[[ "$(db_get_user_field singbox vless-singbox alice enabled)" == false ]] || fail 'disabled flag readback'
assert_json '.inbounds[0].users == []'
assert_json '[.route.rules[] | .auth_user[]?] == []'
db_set_user_enabled singbox vless-singbox bob true
assert_json '.inbounds[0].users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000003"'
printf 'ok - boolean false survives DB reads and disable/enable rebuilds credentials and routes\n'

rewrite_db '.singbox["vless-singbox"] as $first | .singbox["vless-singbox"] = [$first, ($first | .port=45002)]'
db_set_user_enabled singbox vless-singbox bob false
assert_json '.inbounds | length == 2 and all(.[]; .users == [])'
assert_json 'all(.singbox["vless-singbox"][].users[] | select(.name == "bob"); .enabled == false)' "$DB_FILE"
[[ "$(db_get_user_field singbox vless-singbox bob enabled)" == false ]] || fail 'multiport false DB field'
db_set_user_enabled singbox vless-singbox alice true
assert_json '.inbounds | length == 2 and all(.[]; .users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000002")'
[[ "$(wc -l <"$TEST_TMP/reloads")" == 4 ]] || fail 'user mutation did not rebuild exactly once'
printf 'ok - multiport disable/enable updates every listener without restoring legacy credentials\n'
