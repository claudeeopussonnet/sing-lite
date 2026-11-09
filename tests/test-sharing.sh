#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
python3 - "$DB_FILE" <<'PY'
import json, sys
first = dict(port=44001, uuid='00000000-0000-4000-8000-000000000001',
             private_key='test-private', public_key='test-public', short_id='00123456',
             sni='first.example', security_mode='reality')
second = dict(first, port=44002, uuid='00000000-0000-4000-8000-000000000002', sni='second.example')
json.dump(dict(singbox={'vless-singbox':[first, second],
                       'snell-v5':dict(port=44005, psk='testSharedV5Key', version=5),
                       'snell-v6-singbox':dict(port=44006, psk='testSharedV6Key', version=6, mode='unsafe-raw')},
               snell={'snell-v5-official':dict(port=44015, psk='testOfficialV5Key', version=5),
                      'snell-v6':dict(port=44016, psk='testOfficialV6Key', version=6, mode='unshaped')}),
          open(sys.argv[1], 'w'))
PY
gen_v2ray_sub | base64 -d >"$TEST_TMP/generic"
gen_clash_sub >"$TEST_TMP/clash"
gen_surge_sub >"$TEST_TMP/surge"
show_all_share_links >"$TEST_TMP/share"
python3 - "$TEST_TMP" <<'PY'
import pathlib, sys
from urllib.parse import parse_qs, urlsplit
root = pathlib.Path(sys.argv[1])
links = [urlsplit(line) for line in (root/'generic').read_text().splitlines() if line.startswith('vless://')]
assert len(links) == 2, links
for port, last, domain in [(44001,'1','first.example'), (44002,'2','second.example')]:
    link, = [link for link in links if link.port == port]
    assert link.hostname == '192.0.2.1'
    assert link.username == '00000000-0000-4000-8000-00000000000'+last
    query = parse_qs(link.query)
    assert query['security'] == ['reality'] and query['flow'] == ['xtls-rprx-vision']
    assert query['sid'] == ['00123456'] and query['sni'] == [domain]
    assert query['pbk'] == ['test-public']
    assert str(port) in (root/'clash').read_text()
    assert str(port) in (root/'share').read_text()
surge = (root/'surge').read_text()
for port, psk, version in [(44005,'testSharedV5Key',5), (44006,'testSharedV6Key',6), (44015,'testOfficialV5Key',5), (44016,'testOfficialV6Key',6)]:
    rows = [line for line in surge.splitlines() if f', {port},' in line]
    assert len(rows) == 1, (port, rows)
    assert f'psk={psk}' in rows[0] and f'version={version}' in rows[0], rows[0]
assert 'mode=unshaped' in surge
assert 'mode=unsafe-raw' in surge
for port, mode, impl in [(44006,'unsafe-raw','singbox'),(44016,'unshaped','official')]:
    link, = [urlsplit(line) for line in (root/'generic').read_text().splitlines()
             if line.startswith('snell://') and urlsplit(line).port == port]
    query = parse_qs(link.query)
    assert query['version'] == ['6'] and query['mode'] == [mode], link
    assert impl in link.fragment, link
    assert str(port) in (root/'share').read_text()
PY
printf 'ok - multiport REALITY shares and official/shared Snell subscription namespaces\n'

get_connection_addresses() { printf '|2001:db8::1\n'; }
gen_v2ray_sub | base64 -d >"$TEST_TMP/ipv6"
grep -q '@\[2001:db8::1\]:44001?' "$TEST_TMP/ipv6" || fail 'IPv6 subscription host missing brackets'
printf 'ok - IPv6-only subscriptions use bracketed addresses\n'

# External parsing survives removal of the corresponding server protocols.
vmess="vmess://$(printf '%s' '{"v":"2","ps":"external","add":"192.0.2.2","port":"443","id":"00000000-0000-4000-8000-000000000003","aid":"0","net":"ws","path":"/external","tls":"tls","sni":"external.example"}' | base64 -w0)"
parse_vmess_link "$vmess" >"$TEST_TMP/parsed"
assert_json '.type == "vmess" and .server == "192.0.2.2" and .port == 443 and .network == "ws"' "$TEST_TMP/parsed"
parse_trojan_link 'trojan://external-password@192.0.2.3:443?sni=external.example#external' >"$TEST_TMP/parsed"
assert_json '.type == "trojan" and .server == "192.0.2.3" and .port == 443 and .password == "external-password"' "$TEST_TMP/parsed"
printf 'ok - external VMess/Trojan parsing remains supported\n'

# Top-level credentials are legacy metadata once a users list exists. They must
# not reappear in public output when the default user has been disabled.
get_connection_addresses() { printf '192.0.2.1|\n'; }
rewrite_db '.singbox = {"vless-singbox": .singbox["vless-singbox"][0]} |
    .snell = {} |
    .singbox["vless-singbox"].users = [
        {name:"default",uuid:.singbox["vless-singbox"].uuid,enabled:false},
        {name:"active",uuid:"00000000-0000-4000-8000-000000000004",enabled:true},
        {name:"implicit",uuid:"00000000-0000-4000-8000-000000000005"}]'
gen_v2ray_sub | base64 -d >"$TEST_TMP/enabled-generic"
gen_clash_sub >"$TEST_TMP/enabled-clash"
show_all_share_links >"$TEST_TMP/enabled-share"
for output in "$TEST_TMP/enabled-generic" "$TEST_TMP/enabled-clash" "$TEST_TMP/enabled-share"; do
    if grep -q '00000000-0000-4000-8000-000000000001' "$output"; then fail "disabled legacy credential in $output"; fi
    grep -q '00000000-0000-4000-8000-000000000004' "$output" || fail "enabled user missing from $output"
    grep -q '00000000-0000-4000-8000-000000000005' "$output" || fail "implicit enabled user missing from $output"
done
printf 'ok - share/subscription output excludes disabled credentials and includes enabled users\n'
