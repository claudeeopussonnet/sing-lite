#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

python3 - "$DB_FILE" <<'PY'
import json, sys

def uid(number):
    return f'00000000-0000-4000-8000-{number:012d}'

def node(port, number, **extra):
    return dict(port=port, uuid=uid(number), transport='raw', security_mode='reality',
                encryption='none', decryption='none', sni='www.example.com',
                private_key='PRIVATE-DO-NOT-EXPORT', public_key='test-public-key',
                short_id='00123456', dest='www.example.com:443', **extra)

first = node(45101, 1)
first['users'] = [dict(name='alice', uuid=uid(2), enabled=True),
                  dict(name='bob', uuid=uid(3)),
                  dict(name='disabled', uuid=uid(4), enabled=False)]
second = node(45102, 5)
second['users'] = [dict(name='alice', uuid=uid(5), enabled=True)]
encrypted = node(45103, 6)
encrypted.update(encryption='mlkem768x25519plus.native.0rtt.public+/=&?# %',
                 decryption='PRIVATE-DECRYPTION-DO-NOT-EXPORT')
xhttp = node(45111, 7)
xhttp.update(transport='xhttp', xhttp_path='/x http/路径?arg=a&b=#', xhttp_mode='packet-up')
xhttp_enc = dict(xhttp, port=45112, uuid=uid(8), encryption=encrypted['encryption'],
                 decryption=encrypted['decryption'], xhttp_mode='stream-up')
encryption_only = dict(encrypted, port=45121, uuid=uid(9), security_mode='encryption')
json.dump(dict(singbox={'vless-singbox':[node(45201, 11), node(45202, 12)]},
               xray={'vless':[first, second, encrypted], 'vless-xhttp':[xhttp, xhttp_enc],
                     'vless-enc':encryption_only}, snell={}), open(sys.argv[1], 'w'))
PY

gen_v2ray_sub | base64 -d >"$TEST_TMP/generic"
gen_surge_sub >"$TEST_TMP/surge" 2>"$TEST_TMP/surge-skipped"
gen_clash_sub >"$TEST_TMP/clash" 2>"$TEST_TMP/clash-skipped"
show_all_share_links >"$TEST_TMP/details" 2>"$TEST_TMP/details-skipped"
_gen_user_share_link xray vless 00000000-0000-4000-8000-000000000005 alice >"$TEST_TMP/user-second"
_gen_user_share_link xray vless 00000000-0000-4000-8000-000000000002 alice >"$TEST_TMP/user-first"
_gen_user_share_link xray vless 00000000-0000-4000-8000-000000000004 disabled >"$TEST_TMP/user-disabled"
_gen_user_share_link xray vless-enc 00000000-0000-4000-8000-000000000009 default >"$TEST_TMP/user-encryption"

python3 - "$TEST_TMP" <<'PY'
import json, pathlib, re, sys
from urllib.parse import parse_qs, unquote, urlsplit

root = pathlib.Path(sys.argv[1])
links = [urlsplit(line) for line in (root/'generic').read_text().splitlines()]
assert len(links) == 9, links
assert len({unquote(link.fragment) for link in links}) == len(links)
for link in links:
    assert link.hostname == '192.0.2.1', link
    assert str(link.port) in unquote(link.fragment), link
    q = parse_qs(link.query, keep_blank_values=True)
    if link.port in (45111, 45112):
        assert q['type'] == ['xhttp'] and 'flow' not in q, q
        assert q['path'] == ['/x http/路径?arg=a&b=#'], q
        assert q['mode'] == [('packet-up' if link.port == 45111 else 'stream-up')], q
    else:
        assert q['type'] == ['tcp'] and 'path' not in q and 'mode' not in q, q
    if link.port == 45121:
        assert q['security'] == ['none'], q
        assert not {'sni', 'fp', 'pbk', 'sid', 'flow'} & q.keys(), q
    else:
        assert q['security'] == ['reality'] and q['pbk'] == ['test-public-key'], q
        assert q['sid'] == ['00123456'] and q['sni'] == ['www.example.com'], q
        if link.port not in (45111, 45112):
            assert q['flow'] == ['xtls-rprx-vision'], q
    expected = ('mlkem768x25519plus.native.0rtt.public+/=&?# %'
                if link.port in (45103, 45112, 45121) else 'none')
    assert q['encryption'] == [expected], q
    if expected != 'none':
        assert '%2B' in link.query and '%26' in link.query and '%23' in link.query, link
    assert not any(x in link.query for x in [' ', '路径', 'decryption', 'private_key']), link

surge = (root/'surge').read_text()
rows = [line for line in surge.splitlines() if ' = vless,' in line]
assert len(rows) == 5, rows
assert len({row.split(' = ')[0] for row in rows}) == len(rows), rows
assert len([row for row in rows if ', 45101,' in row]) == 2
for row in rows:
    assert 'username=00000000-' in row and 'flow=xtls-rprx-vision' in row, row
    assert 'reality-public-key=test-public-key' in row and 'reality-short-id=00123456' in row, row
    assert 'sni=www.example.com' in row and 'skip-cert-verify' not in row, row
assert any('alice' in row for row in rows) and any('bob' in row for row in rows), rows

clash = (root/'clash').read_text()
assert clash.count('    type: vless') == 5, clash
assert clash.count('      short-id: "00123456"') == 5, clash
names = [json.loads(line.split('name: ', 1)[1]) for line in clash.split('proxy-groups:')[0].splitlines()
         if line.startswith('  - name: ')]
assert len(names) == len(set(names)) == 5, names
for port in (45103, 45111, 45112, 45121):
    assert not re.search(rf', {port},|port: {port}\b', surge + clash), port
    assert str(port) in (root/'surge-skipped').read_text(), port
    assert str(port) in (root/'clash-skipped').read_text(), port
details = (root/'details').read_text()
assert details.count('兼容性：Surge 不支持') == 4, details
for filename, port, user in [('user-first',45101,2), ('user-second',45102,5), ('user-encryption',45121,9)]:
    link, = [urlsplit(line) for line in (root/filename).read_text().splitlines()]
    assert link.port == port and link.username.endswith(f'{user:012d}'), link
    assert str(port) in unquote(link.fragment), link
assert not (root/'user-disabled').read_text()
for filename in ['generic','surge','clash','details','user-first','user-second','user-encryption']:
    text = (root/filename).read_text()
    assert 'PRIVATE-' not in text and 'decryption=' not in text, (filename, text)
    assert '00000000-0000-4000-8000-000000000001' not in text, filename
    assert '00000000-0000-4000-8000-000000000004' not in text, filename
PY
printf 'ok - VLESS subscriptions preserve transport/encryption, unique port/user names and public fields only\n'

get_connection_addresses() { printf '|2001:db8::1\n'; }
gen_v2ray_sub | base64 -d >"$TEST_TMP/ipv6-generic"
gen_surge_sub >"$TEST_TMP/ipv6-surge" 2>"$TEST_TMP/ipv6-skipped"
gen_clash_sub >"$TEST_TMP/ipv6-clash" 2>"$TEST_TMP/ipv6-clash-skipped"
_gen_user_share_link xray vless 00000000-0000-4000-8000-000000000005 alice >"$TEST_TMP/ipv6-user"
cfg=$(db_protocol_configs xray vless-xhttp | head -n 1)
for mode in auto packet-up stream-up stream-one; do
    record=$(jq -c --arg mode "$mode" '.xhttp_mode = $mode' <<< "$cfg")
    gen_xray_vless_link '2001:db8::2' "$record" '用户 # +& /"name"' >>"$TEST_TMP/modes"
done
gen_vless_link '2001:db8::3' 45443 00000000-0000-4000-8000-000000000013 'public+/=' 00 'sni.example' '地区 #+' >"$TEST_TMP/legacy-helper"
python3 - "$TEST_TMP" <<'PY'
import pathlib, sys
from urllib.parse import parse_qs, unquote, urlsplit
root = pathlib.Path(sys.argv[1])
for filename in ('ipv6-generic', 'ipv6-user'):
    for line in (root/filename).read_text().splitlines():
        link = urlsplit(line)
        assert link.hostname == '2001:db8::1' and '@[2001:db8::1]:' in line, line
for row in (root/'ipv6-surge').read_text().splitlines():
    if ' = vless,' in row:
        assert ', [2001:db8::1],' in row, row
assert 'server: "2001:db8::1"' in (root/'ipv6-clash').read_text()
for line, mode in zip((root/'modes').read_text().splitlines(), ('auto','packet-up','stream-up','stream-one')):
    link = urlsplit(line)
    assert link.hostname == '2001:db8::2' and '@[2001:db8::2]:' in line, line
    assert unquote(link.fragment) == '用户 # +& /"name"', line
    query = parse_qs(link.query)
    assert query['mode'] == [mode] and 'flow' not in query, query
link = urlsplit((root/'legacy-helper').read_text().strip())
assert link.hostname == '2001:db8::3' and parse_qs(link.query)['pbk'] == ['public+/='], link
assert '地区 #+' in unquote(link.fragment) and '45443' in unquote(link.fragment), link
PY
printf 'ok - IPv6 URI/Surge output, all XHTTP modes and Unicode/reserved URI values\n'

external='vless://00000000-0000-4000-8000-000000000014@[2001:db8::4]:443?security=reality&type=tcp&pbk=public-key&sid=00123456&sni=www.example.com&flow=xtls-rprx-vision&encryption=none#external%20%22quoted%22'
parse_vless_link "$external" >"$TEST_TMP/parsed-external"
assert_json '.name == "external \"quoted\"" and .server == "2001:db8::4" and .publicKey == "public-key" and .shortId == "00123456" and .transport == "tcp"' "$TEST_TMP/parsed-external"
external_link_to_surge "$external" >"$TEST_TMP/external-surge"
grep -q ' = vless, \[2001:db8::4\], 443, username=' "$TEST_TMP/external-surge" || fail 'external IPv6 VLESS Surge line missing'
grep -q 'reality-public-key=public-key, reality-short-id=00123456' "$TEST_TMP/external-surge" || fail 'external REALITY fields missing'
external_link_to_surge "${external/]:443/]:8443}" >"$TEST_TMP/external-other-port"
[[ $(cut -d= -f1 "$TEST_TMP/external-surge") != "$(cut -d= -f1 "$TEST_TMP/external-other-port")" ]] || fail 'external multiport Surge names collide'
external_link_to_surge "${external/&flow=xtls-rprx-vision/}" >"$TEST_TMP/external-no-flow"
if grep -q 'flow=' "$TEST_TMP/external-no-flow"; then fail 'external no-flow node changed to Vision'; fi
for unsupported in \
    "${external/type=tcp/type=xhttp}" \
    "${external/encryption=none/encryption=mlkem-test}" \
    "${external/type=tcp/type=httpupgrade}"; do
    external_link_to_surge "$unsupported" >"$TEST_TMP/unsupported" 2>"$TEST_TMP/unsupported-error"
    [[ ! -s "$TEST_TMP/unsupported" && -s "$TEST_TMP/unsupported-error" ]] || fail 'unsupported external VLESS exported or skipped silently'
done
printf 'ok - external REALITY converts to Surge; unsupported transports/encryption skip explicitly\n'

# Unsupported local nodes still need an importable subscription with a usable group.
rewrite_db '.singbox = {} | .snell = {} |
    .xray.vless = [.xray.vless[] | select(.encryption != "none")]'
gen_surge_sub >"$TEST_TMP/empty-surge" 2>"$TEST_TMP/empty-surge-skipped"
gen_clash_sub >"$TEST_TMP/empty-clash" 2>"$TEST_TMP/empty-clash-skipped"
(
    get_all_external_links() { printf '%s\n' "$external"; }
    gen_surge_sub
) >"$TEST_TMP/external-only-surge" 2>"$TEST_TMP/external-only-surge-skipped"
(
    get_all_external_links() { printf '%s\n' "$external"; }
    gen_clash_sub
) >"$TEST_TMP/external-only-clash" 2>"$TEST_TMP/external-only-clash-skipped"
python3 - "$TEST_TMP" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
surge = (root/'empty-surge').read_text()
assert '\nProxy = select, DIRECT\n' in surge, surge
assert not surge.split('[Proxy]\n', 1)[1].split('[Proxy Group]', 1)[0].strip(), surge
clash = (root/'empty-clash').read_text()
assert '\nproxies: []\n' in clash, clash
assert '\n    proxies:\n      - DIRECT\n' in clash, clash
assert '    type: vless' not in clash, clash
for filename in ('empty-surge-skipped', 'empty-clash-skipped'):
    skipped = (root/filename).read_text()
    for port in (45103, 45111, 45112, 45121):
        assert str(port) in skipped, (filename, port, skipped)
    assert 'XHTTP / VLESS Encryption' in skipped, skipped
surge = (root/'external-only-surge').read_text()
assert surge.count(' = vless,') == 1 and 'Proxy = select, DIRECT' not in surge, surge
group = surge.split('Proxy = select, ', 1)[1].splitlines()[0]
assert group == surge.split(' = vless,', 1)[0].splitlines()[-1], surge
clash = (root/'external-only-clash').read_text()
assert clash.count('    type: vless') == 1 and '\nproxies: []\n' not in clash, clash
assert '\n      - DIRECT\n' not in clash, clash
PY
printf 'ok - empty Surge/Clash exports fall back to DIRECT; supported external nodes populate groups\n'

# One account can use the same UUID on several ports; selection must keep its port.
rewrite_db '(.xray.vless[0] | .encryption = "none" | .users = [
        {name:"shared",uuid:"00000000-0000-4000-8000-000000000015",enabled:true}]) as $base |
    .xray = {vless:[($base | .port = 45301), ($base | .port = 45302)]}'
qrencode() { printf '%s\n' "${@: -1}" >>"$TEST_TMP/menu-qr"; }
_show_user_share_links xray vless >"$TEST_TMP/menu-single" 2>"$TEST_TMP/menu-single-stderr" <<'INPUT'
2
0
INPUT
_show_user_share_links xray vless >"$TEST_TMP/menu-all" 2>"$TEST_TMP/menu-all-stderr" <<'INPUT'
a
0
INPUT
python3 - "$TEST_TMP" <<'PY'
import pathlib, re, sys
from urllib.parse import urlsplit
root = pathlib.Path(sys.argv[1])
for filename, ports in [('menu-single', [45302]), ('menu-all', [45301, 45302])]:
    text = re.sub(r'\x1b\[[0-9;]*m', '', (root/filename).read_text())
    links = [urlsplit(line.strip()) for line in text.splitlines() if line.strip().startswith('vless://')]
    assert [link.port for link in links] == ports, (filename, links)
    assert '(端口 45301)' in text and '(端口 45302)' in text, text
qr, = (root/'menu-qr').read_text().splitlines()
assert urlsplit(qr).port == 45302, qr
PY
printf 'ok - user menu selection/QR keeps the chosen port; show-all emits each port once\n'
