#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

init_db
rebuild_and_reload_singbox() { printf 'reload\n' >> "$TEST_TMP/reloads"; }
ensure_expire_check_cron() { :; }
db_add singbox vless-singbox '{"port":43101,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","sni":"test.example","short_id":"00123456","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","users":[]}'
db_add_user singbox vless-singbox alice 00000000-0000-4000-8000-000000000002 2099-01-01
jq -e '.singbox["vless-singbox"].users[0] | .name=="alice" and .expire_date=="2099-01-01" and .enabled and (has("quota")|not) and (has("used")|not)' "$DB_FILE" >/dev/null
db_set_user_enabled singbox vless-singbox alice false
[[ $(db_get_user_field singbox vless-singbox alice enabled) == false ]]
db_set_user_tg_binding singbox vless-singbox alice 123 alice-test now
[[ $(db_find_user_by_tg_chat 123) == 'singbox|vless-singbox|alice' ]]
tg_get_user_report_by_chat 123 > "$TEST_TMP/status"
grep -q '已禁用' "$TEST_TMP/status"
if grep -Eq '流量|配额|最后同步' "$TEST_TMP/status"; then fail 'traffic data in Telegram account status'; fi
db_set_user_expire_date singbox vless-singbox alice 2000-01-01
db_set_user_enabled singbox vless-singbox alice true
[[ $(db_get_expired_users) == 'singbox|vless-singbox|alice|2000-01-01|'* ]]
[[ $(check_and_disable_expired_users) == 1 ]]
[[ $(db_get_user_field singbox vless-singbox alice enabled) == false ]]
printf 'ok - accounts retain enabled, expiry and Telegram binding without traffic state\n'

for link in \
    'vless://test@example.com:443?type=xhttp&encryption=none#bad' \
    'vless://test@example.com:443?type=tcp&encryption=mlkem-test#bad'; do
    if parse_proxy_link "$link" > "$TEST_TMP/node" 2> "$TEST_TMP/error"; then fail 'unsupported VLESS imported'; fi
    [[ -s "$TEST_TMP/error" ]] || fail 'unsupported parameter was rejected silently'
    if parse_vless_link "$link" >/dev/null 2>&1; then fail 'external parser accepted unsupported VLESS'; fi
done
node=$(parse_proxy_link 'trojan://test-password@example.com:443?type=ws&path=%2Ftest&host=cdn.example.com&sni=tls.example.com#test')
gen_singbox_chain_outbound "$node" proxy ipv4_only > "$TEST_TMP/outbound"
jq -e '.type=="trojan" and .transport.type=="ws" and .transport.path=="/test" and .transport.headers.Host=="cdn.example.com" and .tls.server_name=="tls.example.com" and .domain_strategy=="ipv4_only"' "$TEST_TMP/outbound" >/dev/null
vmess_json='{"v":"2","ps":"test","add":"example.com","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","net":"ws","path":"/vmess","host":"cdn.example.com","tls":"tls"}'
node=$(parse_proxy_link "vmess://$(printf '%s' "$vmess_json" | base64 -w0)")
gen_singbox_chain_outbound "$node" proxy > "$TEST_TMP/outbound"
jq -e '.type=="vmess" and .tls.enabled and .transport.type=="ws" and .transport.path=="/vmess" and .transport.headers.Host=="cdn.example.com"' "$TEST_TMP/outbound" >/dev/null
printf 'ok - external Trojan/VMess use singbox transports; XHTTP/encryption reject explicitly\n'

db_add snell snell-v5-official '{"port":43102,"psk":"testSnellOfficial5","version":5}'
db_add snell snell-v6 '{"port":43103,"psk":"testSnellOfficial6","version":6,"mode":"default"}'
db_add_user singbox vless-singbox active 00000000-0000-4000-8000-000000000003
db_get_all_protocols > "$TEST_TMP/protocols"
grep -qx snell-v5-official "$TEST_TMP/protocols"
grep -qx snell-v6 "$TEST_TMP/protocols"
gen_v2ray_sub | base64 -d > "$TEST_TMP/sub"
grep -q ':43101.*security=reality.*type=tcp' "$TEST_TMP/sub"
grep -q 'pbk=Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo' "$TEST_TMP/sub"
grep -q ':43102' "$TEST_TMP/sub"
grep -q ':43103' "$TEST_TMP/sub"
gen_surge_sub > "$TEST_TMP/surge"
grep -q 'version=5' "$TEST_TMP/surge"
grep -q 'version=6' "$TEST_TMP/surge"
if setup_warp_ipv6_chain >/dev/null 2>&1; then fail 'unsupported WARP chain reported success'; fi
if manage_ip_routing >/dev/null 2>&1; then fail 'unsupported multi-IP reported success'; fi
printf 'ok - official Snell namespace and REALITY subscriptions; unsupported wizards fail\n'
