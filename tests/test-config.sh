#!/usr/bin/env bash
# Set SING_TEST_SINGBOX_BIN to an official binary for schema validation as well.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mkdir -p "$CFG/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test.example \
    -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" >"$TEST_TMP/openssl.log" 2>&1
python3 - "$DB_FILE" <<'PY'
import base64, json, sys
uuid = '00000000-0000-4000-8000-000000000001'
disabled = '00000000-0000-4000-8000-000000000099'
protocols = 'vless-singbox ss2022 ss-legacy socks hy2 tuic anytls naive ss2022-shadowtls snell-v5 snell-v6-singbox'.split()
records = {}
for i, proto in enumerate(protocols):
    record = dict(port=43000+i, uuid=uuid, password='test-password', username='default',
                  sni='test.example', security_mode='reality', short_id='00123456',
                  private_key='eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU',
                  public_key='Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo',
                  auth_mode='password', method='aes-128-gcm', psk='testSnellV5Key123', version=5,
                  stls_password='test-shadowtls-password')
    if proto in ('ss2022', 'ss2022-shadowtls'):
        record.update(method='2022-blake3-aes-128-gcm', password=base64.b64encode(b'0123456789abcdef').decode())
    if proto == 'snell-v6-singbox':
        record.update(version=6, mode='unshaped')
    if proto.startswith('vless') or proto in ('socks', 'hy2', 'tuic', 'anytls', 'naive'):
        record['users'] = [dict(name='active', uuid=uuid, password='test-active', username='active', enabled=True),
                           dict(name='implicit', uuid='00000000-0000-4000-8000-000000000002', password='test-implicit', username='implicit'),
                           dict(name='disabled', uuid=disabled, password='DISABLED-PASSWORD', username='disabled', enabled=False)]
    records[proto] = record
json.dump(dict(singbox=records, snell={}, routing=dict(warp_mode='disabled')), open(sys.argv[1], 'w'))
PY
generate_singbox_config >"$TEST_TMP/generate.log"
assert_json '(.inbounds | length) == 12 and ([.inbounds[].tag]|length) == ([.inbounds[].tag]|unique|length)'
assert_json '[.inbounds[] | select(.type == "vless")] | length == 1'
assert_json 'all(.inbounds[] | select(.type == "vless") | .users; length == 2)'
assert_json 'all(.inbounds[] | select(.type == "vless") | .users[]; .flow == "xtls-rprx-vision")'
assert_json 'all(.inbounds[] | select(.type == "vless"); (has("transport") | not) and .tls.enabled and .tls.reality.enabled)'
assert_json 'any(.inbounds[]; .listen_port == 43000 and .tls.reality.short_id == ["00123456"] and .tls.reality.private_key == "eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU")'
assert_json 'all(.inbounds[] | select(.type == "hysteria2" or .type == "tuic" or .type == "anytls" or .type == "naive" or .type == "socks") | .users; length == 2)'
assert_json 'any(.inbounds[]; .type == "shadowtls" and .version == 3 and .detour != null)'
assert_json 'any(.inbounds[]; .type == "snell" and .version == 5)'
assert_json 'any(.inbounds[]; .type == "snell" and .version == 6 and .mode == "unshaped")'
if grep -Eq 'DISABLED-PASSWORD|00000000-0000-4000-8000-000000000099|"disabled"' "$CFG/singbox.json"; then fail 'disabled credential leaked into config'; fi
sing-box check -c "$CFG/singbox.json"
printf 'ok - all supported protocols, enabled/default users and official configuration schema\n'

# An explicit empty list must never restore a top-level/default credential.
rewrite_db '.singbox |= with_entries(select(.key == "vless-singbox")) | .singbox["vless-singbox"].users = []'
generate_singbox_config >"$TEST_TMP/generate.log"
assert_json '.inbounds | length == 1 and .[0].users == []'
rewrite_db '.singbox["vless-singbox"].users = [{name:"disabled",uuid:"00000000-0000-4000-8000-000000000099",enabled:false}]'
generate_singbox_config >"$TEST_TMP/generate.log"
assert_json '.inbounds[0].users == []'
rewrite_db 'del(.singbox["vless-singbox"].users)'
generate_singbox_config >"$TEST_TMP/generate.log"
assert_json '.inbounds[0].users | length == 1 and .[0].uuid == "00000000-0000-4000-8000-000000000001"'
printf 'ok - explicit empty/all-disabled users do not reactivate default credentials\n'

# Unknown protocols and failed checks must not replace the last working file.
cp "$CFG/singbox.json" "$TEST_TMP/working.json"
for protocol in snell-v4 vless-vision vless-ws vless-ws-notls; do
    rewrite_db ".singbox[\"$protocol\"] = {port:43999,psk:\"removed\",version:4}"
    if generate_singbox_config >"$TEST_TMP/rejected.log" 2>&1; then fail "unsupported server protocol generated: $protocol"; fi
    cmp "$TEST_TMP/working.json" "$CFG/singbox.json"
    rewrite_db "del(.singbox[\"$protocol\"])"
done
sing-box() {
    case "$1" in version) printf 'sing-box version 1.14.4\n' ;; check) return 1 ;; *) forbidden sing-box "$@" ;; esac
}
if generate_singbox_config >"$TEST_TMP/rejected.log" 2>&1; then fail 'failed binary validation accepted'; fi
cmp "$TEST_TMP/working.json" "$CFG/singbox.json"
printf 'ok - unsupported protocols and failed validation preserve working config\n'
