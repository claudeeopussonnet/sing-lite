#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
init_db
get_ip_country() { printf 'JP\n'; }

# Export transport/security fields exactly; changing the display name must not change them.
base='vless://MixedUser@[2001:db8::2]:443?security=reality&pbk=MixedPublicKey&sid=00123456&sni=MiXeD.example'
path='/MiXeD,路径?arg=a&b="Case"'
host='MiXeD.example'
enc='mlkem768x25519plus.native.0rtt.MixedClientKey'
for mode in auto packet-up stream-up stream-one; do
    for encryption in none "$enc"; do
        link="${base}&type=xhttp&path=$(urlencode "$path")&host=$host&mode=$mode&encryption=$encryption#OldLongName"
        parse_vless_link "$link" >>"$TEST_TMP/parsed"
        external_link_to_surge "$link" >>"$TEST_TMP/rows"
        printf '%s\n' "$link" >>"$EXTERNAL_LINKS_FILE"
    done
done
external_link_to_surge "${base}&type=splithttp&mode=stream-one&extra=%7B%7D" >"$TEST_TMP/alias"
external_link_to_surge "${base}&type=raw&flow=xtls-rprx-vision-udp443&encryption=$enc" >"$TEST_TMP/raw"
external_link_to_surge "vless://MixedUser@192.0.2.2:8443?security=none&type=tcp&encryption=$enc&flow=xtls-rprx-vision" >"$TEST_TMP/encryption-only"
for unsupported in \
    "${base}&type=ws" \
    "${base/reality/tls}&type=tcp" \
    "${base}&type=xhttp&extra=%7B%22downloadSettings%22%3A%7B%7D%7D" \
    "${base}&type=xhttp&downloadSettings=unsupported" \
    "${base}&type=xhttp&extra=false" \
    "${base}&type=xhttp&mode=invalid" \
    "${base}&type=xhttp&flow=xtls-rprx-vision" \
    "${base}&type=xhttp&path=%2Fsafe%0AInjected%3Dtrue" \
    'vless://MixedUser@192.0.2.2:443?security=reality&type=raw' ; do
    external_link_to_surge "$unsupported" >"$TEST_TMP/rejected" 2>"$TEST_TMP/rejected-stderr"
    [[ ! -s "$TEST_TMP/rejected" && -s "$TEST_TMP/rejected-stderr" ]] || fail 'unsupported/unsafe Surge node exported silently'
    printf '%s\n' "$unsupported" >>"$EXTERNAL_LINKS_FILE"
done
gen_surge_sub >"$TEST_TMP/subscription" 2>"$TEST_TMP/skipped"
# The neutral parser accepts supported exports; sing-box still rejects their capabilities.
parse_vless_link "${base}&type=xhttp&encryption=$enc" >"$TEST_TMP/node"
if gen_singbox_chain_outbound "$(cat "$TEST_TMP/node")" >/dev/null 2>&1; then fail 'sing-box chain accepted XHTTP/Encryption'; fi
python3 - "$TEST_TMP" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);rows=(root/'rows').read_text().splitlines()
assert len(rows)==8,rows
for i,(row,node) in enumerate(zip(rows,map(json.loads,(root/'parsed').read_text().splitlines()))):
    mode=('auto','packet-up','stream-up','stream-one')[i//2]
    assert node['mode']==mode and node['path']=='/MiXeD,路径?arg=a&b="Case"',node
    assert 'username=MixedUser' in row and 'sni=MiXeD.example' in row,row
    assert 'reality-public-key=MixedPublicKey' in row and 'reality-short-id=00123456' in row,row
    assert f'xhttp-mode={mode}' in row and 'xhttp-host=MiXeD.example' in row,row
    assert 'xhttp-path='+json.dumps(node['path'],ensure_ascii=False) in row,row
    assert ('encryption=mlkem768x25519plus.native.0rtt.MixedClientKey' in row)==bool(i%2),row
    assert 'flow=' not in row and 'tls=' not in row and 'skip-cert-verify=' not in row,row
    assert row.startswith('🇯🇵 XHTTP'+('+ENC' if i%2 else '')+'-443 = '),row
assert 'xhttp=true' in (root/'alias').read_text()
assert 'xhttp-mode=stream-one' in (root/'alias').read_text()
raw=(root/'raw').read_text()
assert 'flow=xtls-rprx-vision-udp443' in raw and 'encryption=' in raw and 'xhttp=' not in raw,raw
enc=(root/'encryption-only').read_text()
assert enc.startswith('🇯🇵 ENC-8443 = ') and 'flow=xtls-rprx-vision' in enc,enc
assert 'reality-' not in enc and 'sni=' not in enc and 'tls=' not in enc,enc
sub=(root/'subscription').read_text()
exported=[line for line in sub.splitlines() if ' = vless,' in line]
assert len(exported)==8 and len({line.split(' = ')[0] for line in exported})==8,sub
group=sub.split('Proxy = select, ',1)[1].splitlines()[0].split(', ')
assert set(group)=={line.split(' = ')[0] for line in exported},sub
assert (root/'skipped').read_text().count('Surge 跳过外部 VLESS 节点')==9
assert not any(x in sub for x in ('Injected','decryption=','private_key=')),sub
PY
printf 'ok - external Surge XHTTP modes/host/encoding, Encryption/Vision, explicit unsupported/unsafe rejection\n'
