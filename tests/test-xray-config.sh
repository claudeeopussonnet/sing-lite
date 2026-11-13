#!/usr/bin/env bash
# All configs, binaries and validation calls stay inside the temporary fixture.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { :; }
xray() {
    [[ "$1 $2 $3 $4 $5" == 'run -test -format json -c' && $# == 6 ]] || forbidden xray "$@"
    [[ "$6" == *.json ]] || fail 'candidate is missing the JSON extension'
    printf '%s\n' "$6" >>"$TEST_TMP/checks"
    jq -e '.outbounds == [{protocol:"freedom",tag:"direct"}] and (has("routing") | not)' "$6" >/dev/null
    if [[ -n "${SING_TEST_XRAY_BIN:-}" ]]; then
        "$SING_TEST_XRAY_BIN" "$@" || return 1
    fi
    if [[ "${FAIL_CHECK:-false}" == true ]]; then
        printf 'Failed to start: rejected fixture candidate\n'
        printf 'fixture validation detail on stderr\n' >&2
        return 1
    fi
    return 0
}
init_db
raw='{"port":47001,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","transport":"raw","sni":"test.example","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","short_id":"00123456","encryption":"none","decryption":"none"}'
client='mlkem768x25519plus.native.1rtt.mockClientKey'
server='mlkem768x25519plus.native.600s.mockServerKey'
if [[ -n "${SING_TEST_XRAY_BIN:-}" ]]; then
    [[ -x "$SING_TEST_XRAY_BIN" ]] || fail 'SING_TEST_XRAY_BIN is not executable'
    keys=$(XRAY_CONFIG_BINARY="$SING_TEST_XRAY_BIN" gen_xray_reality_keys)
    raw=$(jq --argjson keys "$keys" '. + $keys' <<<"$raw")
    keys=$(XRAY_CONFIG_BINARY="$SING_TEST_XRAY_BIN" gen_xray_encryption)
    client=$(jq -r '.encryption' <<<"$keys")
    server=$(jq -r '.decryption' <<<"$keys")
fi
jq -n --argjson raw "$raw" --arg client "$client" --arg server "$server" '
    {singbox:{socks:{port:47090}},snell:{},routing:{warp_mode:"all"},xray:{
        vless:[$raw,($raw | .port=47002 | .dest="[2001:db8::2]:8443" | .encryption=$client | .decryption=$server |
            .users=[{name:"alice",uuid:"00000000-0000-4000-8000-000000000002",enabled:true},
                    {name:"disabled",uuid:"00000000-0000-4000-8000-000000000003",enabled:false}])],
        "vless-xhttp":($raw | .port=47003 | .transport="xhttp" | .xhttp_path="/test?query=1" | .xhttp_mode="packet-up"),
        "vless-enc":{port:47004,uuid:"00000000-0000-4000-8000-000000000004",transport:"raw",security_mode:"encryption",encryption:$client,decryption:$server}}}
' >"$DB_FILE"
if ! generate_xray_config >"$TEST_TMP/check-stdout" 2>"$TEST_TMP/check-stderr"; then
    cat "$TEST_TMP/check-stderr" >&2
    fail 'generated fixture config failed validation'
fi
[[ ! -s "$TEST_TMP/check-stdout" && ! -s "$TEST_TMP/check-stderr" ]] || fail 'successful validation produced output'
assert_json '.inbounds | length == 4' "$CFG/xray.json"
assert_json 'all(.inbounds[]; .listen == "127.0.0.1" and .protocol == "vless")' "$CFG/xray.json"
assert_json '.inbounds[] | select(.port == 47001) | .settings.decryption == "none" and .settings.clients == [{id:"00000000-0000-4000-8000-000000000001",flow:"xtls-rprx-vision"}] and .streamSettings.network == "raw" and .streamSettings.security == "reality" and .streamSettings.realitySettings.target == "test.example:443"' "$CFG/xray.json"
jq -e --arg server "$server" '.inbounds[] | select(.port == 47002) | .settings.clients == [{id:"00000000-0000-4000-8000-000000000002",flow:"xtls-rprx-vision",email:"alice"}] and .settings.decryption == $server and .streamSettings.realitySettings.target == "[2001:db8::2]:8443"' "$CFG/xray.json" >/dev/null || fail 'enabled users and server encryption'
assert_json '.inbounds[] | select(.port == 47003) | .streamSettings.xhttpSettings == {path:"/test?query=1",mode:"packet-up"} and all(.settings.clients[]; has("flow") | not)' "$CFG/xray.json"
assert_json '.inbounds[] | select(.port == 47004) | .streamSettings == {network:"raw",security:"none"} and all(.settings.clients[]; has("flow") | not)' "$CFG/xray.json"
[[ "$(stat -c %a "$CFG/xray.json")" == 600 ]] || fail 'config permissions'
[[ "$(wc -l <"$TEST_TMP/checks")" == 1 ]] || fail 'missing Xray candidate check'
printf 'ok - object/array records, transports, REALITY and Encryption produce checked independent Xray config\n'
if [[ -n "${SING_TEST_XRAY_BIN:-}" ]]; then
    jq --arg client "$client" --arg server "$server" \
        '.xray["vless-xhttp"] += {encryption:$client,decryption:$server}' "$DB_FILE" >"$TEST_TMP/encrypted-db.json"
    mv "$TEST_TMP/encrypted-db.json" "$DB_FILE"
    for mode in auto packet-up stream-up stream-one; do
        rewrite_db ".xray[\"vless-xhttp\"].xhttp_mode=\"$mode\""
        # Exercise the actual CLI directly, with no shell mock or argument wrapper.
        XRAY_CONFIG_BINARY="$SING_TEST_XRAY_BIN" generate_xray_config "$TEST_TMP/official.json"
    done
    printf 'ok - official Xray CLI validates every XHTTP mode with Encryption alongside RAW REALITY and Encryption\n'
fi

# Explicit users are authoritative, including an empty array or all disabled users.
rewrite_db '.xray.vless[0].users=[] | .xray.vless[1].users |= map(.enabled=false) | .xray["vless-xhttp"].users=[] | .xray["vless-enc"].users=[]'
generate_xray_config
assert_json '.inbounds == [] and .outbounds == [{protocol:"freedom",tag:"direct"}]' "$CFG/xray.json"
if grep -q '00000000-' "$CFG/xray.json"; then fail 'explicit users leaked fallback UUID'; fi
rewrite_db '.xray.vless[0].users=[{uuid:"00000000-0000-4000-8000-000000000009",enabled:true}]'
generate_xray_config
assert_json '.inbounds | length == 1 and .[0].settings.clients[0].id == "00000000-0000-4000-8000-000000000009"' "$CFG/xray.json"
printf 'ok - empty/disabled users remove listeners safely without legacy credential fallback\n'

cp -p "$CFG/xray.json" "$TEST_TMP/previous.json"
cp -p "$DB_FILE" "$TEST_TMP/valid-db.json"
for mutation in \
    '.xray.vless[0].port=0' \
    '.xray.vless[0].port=65536' \
    '.xray.vless[0].port=443.5' \
    '.xray.vless[0].port="443"' \
    '.xray.vless[0].port=.xray.vless[1].port' \
    'del(.xray.vless[0].private_key)' \
    'del(.xray.vless[0].public_key)' \
    'del(.xray.vless[0].short_id)' \
    '.xray.vless[0].short_id="a"' \
    '.xray.vless[0].sni="bad host"' \
    '.xray.vless[0].dest="test.example:99999"' \
    '.xray.vless[0].dest="test.example"' \
    '.xray.vless[0].dest=false' \
    '.xray.vless[0].encryption=false' \
    '.xray.vless[0].decryption=null' \
    '.xray.vless[0].transport="xhttp"' \
    '.xray.vless[0].security_mode="encryption"' \
    '.xray["vless-xhttp"].transport="raw"' \
    '.xray["vless-xhttp"].xhttp_mode="invalid"' \
    '.xray["vless-xhttp"].xhttp_mode=false' \
    '.xray["vless-xhttp"].xhttp_path="missing-slash"' \
    '.xray["vless-xhttp"].xhttp_path="/has space"' \
    '.xray["vless-enc"].security_mode="reality"' \
    '.xray["vless-enc"].encryption="none"' \
    'del(.xray["vless-enc"].decryption)' \
    '.xray["vless-enc"].decryption="mlkem768x25519plus.xorpub.600s.mockServerKey"' \
    '.xray.vless[0].users=null' \
    '.xray.vless[0].users=[{uuid:"bad-uuid"}]' \
    '.xray.vless[0].users=[{uuid:"00000000-0000-4000-8000-000000000001",enabled:"false"}]' \
    '.xray.vless[0].users=[{uuid:"00000000-0000-4000-8000-000000000001"},{uuid:"00000000-0000-4000-8000-000000000001"}]' \
    '.xray.vless=42' \
    '.xray=false' \
    '.xray=null'; do
    jq "$mutation" "$TEST_TMP/valid-db.json" >"$DB_FILE"
    if generate_xray_config 2>"$TEST_TMP/validation-error"; then fail "accepted invalid record: $mutation"; fi
    cmp "$TEST_TMP/previous.json" "$CFG/xray.json" || fail 'invalid DB replaced live config'
done
cp -p "$TEST_TMP/valid-db.json" "$DB_FILE"
FAIL_CHECK=true
if generate_xray_config >"$TEST_TMP/check-stdout" 2>"$TEST_TMP/check-stderr"; then fail 'failed core check replaced config'; fi
[[ ! -s "$TEST_TMP/check-stdout" ]] || fail 'failed validation did not redirect diagnostic to stderr'
grep -q 'Failed to start: rejected fixture candidate' "$TEST_TMP/check-stderr" || fail 'lost core stdout diagnostic'
grep -q 'fixture validation detail on stderr' "$TEST_TMP/check-stderr" || fail 'lost core stderr diagnostic'
cmp "$TEST_TMP/previous.json" "$CFG/xray.json"
FAIL_CHECK=false
if compgen -G "$CFG/xray.json.tmp.*" >/dev/null; then fail 'candidate config leaked'; fi
if compgen -G "$CFG/.xray-check.*" >/dev/null; then fail 'core check log leaked'; fi
printf 'ok - invalid records and failed core checks preserve live config and clean candidates\n'
(
    mv() {
        if [[ "$1" == -f && "$2" == "$CFG"/xray.json.tmp.*/config.json ]]; then return 1; fi
        command mv "$@"
    }
    if generate_xray_config; then fail 'failed atomic rename reported success'; fi
    cmp "$TEST_TMP/previous.json" "$CFG/xray.json" || fail 'failed rename replaced live config'
    if compgen -G "$CFG/xray.json.tmp.*" >/dev/null; then fail 'failed rename leaked candidate/log directory'; fi
)
printf 'ok - failed atomic rename preserves live config and cleans candidate/check log\n'

# An injected executable has priority over the shell mock, including paths with spaces.
mkdir -p "$TEST_TMP/binary directory" "$CFG/bin"
printf '#!/usr/bin/env bash\n[[ "$1 $2 $3 $4 $5" == "run -test -format json -c" ]] && jq empty "$6"\n' >"$TEST_TMP/binary directory/xray"
chmod 755 "$TEST_TMP/binary directory/xray"
XRAY_CONFIG_BINARY="$TEST_TMP/binary directory/xray"
[[ "$(_lite_xray_binary)" == "$XRAY_CONFIG_BINARY" ]] || fail 'binary override priority'
generate_xray_config "$TEST_TMP/override.json"
unset XRAY_CONFIG_BINARY
[[ "$(_lite_xray_binary)" == xray ]] || fail 'shell mock priority'
cp -p "$TEST_TMP/binary directory/xray" "$CFG/bin/xray"
unset -f xray
[[ "$(_lite_xray_binary)" == "$CFG/bin/xray" ]] || fail 'owned binary path'
generate_xray_config "$TEST_TMP/owned.json"
printf 'ok - candidate binary override, shell mock and owned binary priority\n'
if [[ -n "${SING_TEST_XRAY_BIN:-}" ]]; then
    printf 'ok - official Xray validates config with generated REALITY and Encryption keys\n'
fi
