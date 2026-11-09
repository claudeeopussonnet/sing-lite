#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Test the new overrides alone, and their precedence over legacy aliases.
env -u VLESS_TEST_CFG -u VLESS_TEST_SYSTEMD_DIR -u VLESS_TEST_OPENRC_DIR \
    bash -c 'source "$1"; [[ "$CFG" == "$SING_TEST_CFG" && "$SYSTEMD_DIR" == "$SING_TEST_SYSTEMD_DIR" && "$OPENRC_DIR" == "$SING_TEST_OPENRC_DIR" ]]' \
    test "$TEST_ROOT/vless-server.sh" || fail 'SING_TEST overrides require legacy aliases'
VLESS_TEST_CFG="$TEST_TMP/wrong-legacy-path" bash -c \
    'source "$1"; [[ "$CFG" == "$SING_TEST_CFG" ]]' test "$TEST_ROOT/vless-server.sh" || fail 'legacy override took precedence'
env -u SING_TEST_CFG -u VLESS_TEST_CFG bash -c \
    'source "$1"; [[ "$CFG" == /etc/sing-lite ]]' test "$TEST_ROOT/vless-server.sh" || fail 'default configuration identity'
for binary in sing-box snell-server-v5 snell-server-v6; do
    [[ "$(_core_binary_path "$binary")" == "$CFG/bin/$binary" ]] || fail "managed binary path: $binary"
done

expected='vless-singbox vless-vision vless-ws vless-ws-notls ss2022 ss-legacy socks hy2 tuic anytls naive ss2022-shadowtls snell-v5 snell-v6-singbox'
[[ "$SINGBOX_PROTOCOLS" == "$expected" ]] || fail 'unexpected Sing-box protocol registry'
[[ "$STANDALONE_PROTOCOLS" == 'snell-v5-official snell-v6' ]] || fail 'unexpected standalone registry'
for protocol in $expected; do
    [[ "$(protocol_core "$protocol")" == singbox ]] || fail "$protocol ownership"
    [[ "$(protocol_db_core "$protocol")" == singbox ]] || fail "$protocol namespace"
    [[ "${PROTO_BIN[$protocol]}" == sing-box ]] || fail "$protocol executable"
done
for protocol in snell-v5-official snell-v6; do
    [[ "$(protocol_core "$protocol")" == standalone ]] || fail "$protocol ownership"
    for resolver in protocol_db_core protocol_active_db_core protocol_subscription_db_core protocol_uninstall_db_core; do
        [[ "$($resolver "$protocol")" == snell ]] || fail "$resolver $protocol namespace"
    done
done
for protocol in '' unknown vless vmess-ws trojan mieru snell snell-v4 snell-v5-shadowtls; do
    if protocol_core "$protocol" >"$TEST_TMP/rejected" 2>&1; then fail "accepted removed/unknown protocol '$protocol'"; fi
    if protocol_db_core "$protocol" >"$TEST_TMP/rejected" 2>&1; then fail "resolved removed/unknown protocol '$protocol'"; fi
done
init_db
assert_json '(.singbox == {}) and (.snell == {}) and (has("xray")|not) and (has("mihomo")|not)' "$DB_FILE"
[[ "$(stat -c %a "$DB_FILE")" == 600 ]] || fail 'database permissions'
cp "$DB_FILE" "$TEST_TMP/db.before"
init_db
cmp "$TEST_TMP/db.before" "$DB_FILE"
printf 'ok - protocol ownership, rejected legacy protocols, idempotent database without Xray\n'

select_snell_v5_implementation <<<'' >"$TEST_TMP/selection"
[[ "$SELECTED_PROTOCOL" == snell-v5 ]] || fail 'v5 default implementation'
select_snell_v5_implementation <<<2 >"$TEST_TMP/selection"
[[ "$SELECTED_PROTOCOL" == snell-v5-official ]] || fail 'v5 official implementation'
if select_snell_v5_implementation <<<0 >"$TEST_TMP/selection"; then fail 'v5 cancel succeeded'; fi
select_snell_v6_implementation <<<'' >"$TEST_TMP/selection"
[[ "$SELECTED_PROTOCOL" == snell-v6-singbox ]] || fail 'v6 default implementation'
select_snell_v6_implementation <<<2 >"$TEST_TMP/selection"
[[ "$SELECTED_PROTOCOL" == snell-v6 ]] || fail 'v6 official implementation'
if select_snell_v6_implementation <<<0 >"$TEST_TMP/selection"; then fail 'v6 cancel succeeded'; fi

db_add snell snell-v5-official '{"port":42505,"psk":"test-official-v5","version":5}'
db_add snell snell-v6 '{"port":42506,"psk":"testOfficialV6Key123","version":6}'
db_add singbox snell-v5 '{"port":42515,"psk":"test-singbox-v5","version":5}'
[[ "$(db_get_all_protocols | sort)" == $'snell-v5\nsnell-v5-official\nsnell-v6' ]] || fail 'installed Snell protocols'
assert_json '.snell["snell-v5-official"].port == 42505 and .snell["snell-v6"].port == 42506 and .singbox["snell-v5"].port == 42515' "$DB_FILE"
generate_singbox_config >"$TEST_TMP/generate.log"
assert_json '.inbounds | length == 1 and .[0].type == "snell" and .[0].version == 5 and .[0].listen_port == 42515'
printf 'ok - official Snell v5/v6 stay separate from shared Snell v5\n'
