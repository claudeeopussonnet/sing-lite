#!/usr/bin/env bash
# Match ENC server flow against every client export without touching host services.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
init_db
xray() {
    [[ "$1 $2 $3 $4 $5" == 'run -test -format json -c' && $# == 6 ]] || forbidden xray "$@"
    jq empty "$6"
}
qrencode() {
    cat >>"$TEST_TMP/qr-input"
    printf '\n' >>"$TEST_TMP/qr-input"
    printf '[mock QR]\n'
}
jq -n '
    def uid($n): "00000000-0000-4000-8000-00000000000" + ($n | tostring);
    {transport:"raw",security_mode:"encryption",
     encryption:"mlkem768x25519plus.native.1rtt.mockClientKey",
     decryption:"mlkem768x25519plus.native.600s.mockServerKey"} as $base |
    {singbox:{},snell:{},xray:{"vless-enc":[
        ($base + {port:48101,uuid:uid(1)}),
        ($base + {port:48102,uuid:uid(2),flow:""}),
        ($base + {port:48103,uuid:uid(3),flow:"xtls-rprx-vision",users:[
            {name:"alice",uuid:uid(3),enabled:true},
            {name:"bob",uuid:uid(4)},
            {name:"disabled",uuid:uid(5),enabled:false}]})]}}
' >"$DB_FILE"
generate_xray_config
regenerate_xray_protocol_join_info vless-enc
gen_v2ray_sub | base64 -d >"$TEST_TMP/generic"
gen_surge_sub >"$TEST_TMP/surge"
show_all_share_links >"$TEST_TMP/details"
for account in '48101 1 default' '48102 2 default' '48103 3 alice' '48103 4 bob'; do
    read -r port suffix name <<<"$account"
    _gen_user_share_link xray vless-enc "00000000-0000-4000-8000-00000000000$suffix" "$name" "$port" >>"$TEST_TMP/users"
done
_gen_user_share_link xray vless-enc 00000000-0000-4000-8000-000000000005 disabled 48103 >"$TEST_TMP/disabled"
get_connection_addresses() { printf '|2001:db8::1\n'; }
gen_v2ray_sub | base64 -d >"$TEST_TMP/ipv6-generic"
gen_surge_sub >"$TEST_TMP/ipv6-surge"
_gen_user_share_link xray vless-enc 00000000-0000-4000-8000-000000000003 alice 48103 >"$TEST_TMP/ipv6-user"
python3 - "$TEST_TMP" "$CFG" <<'PY'
import base64, json, pathlib, sys
from urllib.parse import parse_qs, unquote, urlsplit

root, cfg = map(pathlib.Path, sys.argv[1:])
expected = {48101: {1}, 48102: {2}, 48103: {3, 4}}
config = json.loads((cfg/'xray.json').read_text())
assert len(config['inbounds']) == 3, config
for inbound in config['inbounds']:
    port = inbound['port']
    assert inbound['streamSettings'] == {'network': 'raw', 'security': 'none'}, inbound
    assert inbound['settings']['decryption'] == 'mlkem768x25519plus.native.600s.mockServerKey', inbound
    clients = inbound['settings']['clients']
    assert {int(c['id'][-12:]) for c in clients} == expected[port], clients
    for client in clients:
        assert client.get('flow', '') == ('xtls-rprx-vision' if port == 48103 else ''), client

def check_link(line):
    link = urlsplit(line)
    query = parse_qs(link.query, keep_blank_values=True)
    assert link.hostname in ('192.0.2.1', '2001:db8::1'), link
    assert int(link.username[-12:]) in expected[link.port], link
    assert query['security'] == ['none'] and query['type'] == ['tcp'], query
    assert query['encryption'] == ['mlkem768x25519plus.native.1rtt.mockClientKey'], query
    assert query.get('flow') == (['xtls-rprx-vision'] if link.port == 48103 else None), query
    assert not {'sni', 'pbk', 'sid', 'fp'} & query.keys(), query
    return link

generic = (root/'generic').read_text().splitlines()
assert len(generic) == 4 and len(set(generic)) == 4, generic
for filename in ('generic', 'users', 'qr-input', 'ipv6-generic', 'ipv6-user'):
    lines = (root/filename).read_text().splitlines()
    assert len(lines) == (1 if filename == 'ipv6-user' else 4), (filename, lines)
    for line in lines:
        link = check_link(line)
        assert link.hostname == ('2001:db8::1' if filename.startswith('ipv6') else '192.0.2.1'), link
assert set((root/'users').read_text().splitlines()) == set(generic)
assert set((root/'qr-input').read_text().splitlines()) == set(generic)
assert not (root/'disabled').read_text()

for filename in ('surge', 'ipv6-surge'):
    rows = [line for line in (root/filename).read_text().splitlines() if ' = vless,' in line]
    assert len(rows) == 4, rows
    for row in rows:
        port = int(row.split(', ')[2])
        assert ('flow=xtls-rprx-vision' in row) == (port == 48103), row
        assert 'encryption=mlkem768x25519plus.native.1rtt.mockClientKey' in row, row
        assert not any(field in row for field in ('tls=', 'sni=', 'reality-')), row
        assert ('[2001:db8::1]' if filename.startswith('ipv6') else '192.0.2.1') in row, row

join = (cfg/'vless-enc.join').read_text().splitlines()
direct = [line.split('=', 1)[1] for line in join if line.startswith('VLESS_ENC_')]
encoded = [base64.b64decode(line.split('=', 1)[1]).decode() for line in join if line.startswith('JOIN_')]
assert len(direct) == len(encoded) == 8 and set(direct) == set(encoded), join
for line in direct:
    check_link(line)
def normalized(line):
    link = urlsplit(line)
    return link._replace(fragment=unquote(link.fragment))
for host, filename in (('192.0.2.1', 'generic'), ('2001:db8::1', 'ipv6-generic')):
    assert {normalized(line) for line in direct if urlsplit(line).hostname == host} == {
        normalized(line) for line in (root/filename).read_text().splitlines()}, (host, direct)
for path in [root/name for name in ('generic', 'surge', 'details', 'users', 'qr-input', 'ipv6-generic', 'ipv6-surge', 'ipv6-user')] + [cfg/'vless-enc.join', cfg/'join.txt']:
    content = path.read_text()
    assert not any(secret in content for secret in ('mockServerKey', 'decryption', 'private_key', '00000000-0000-4000-8000-000000000005')), path
PY
printf 'ok - ENC legacy/off/on flow matches server, URI, Surge, user, QR and JOIN exports over IPv4/IPv6\n'
