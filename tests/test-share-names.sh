#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

get_ip_country() {
    printf '%s\n' "$1" >>"$TEST_TMP/country-queries"
    case "$1" in
        192.0.2.*) printf 'jp\n' ;;
        2001:db8::*) printf 'SG\n' ;;
        *) printf 'XX\n' ;;
    esac
}
dig() {
    printf '%s\n' "$*" >>"$TEST_TMP/dns-queries"
    case "$*" in
        *' A v4.example') printf '192.0.2.2\n' ;;
        *' AAAA v6.example') printf '2001:db8::2\n' ;;
    esac
    return 0
}
python3 - "$DB_FILE" "$EXTERNAL_LINKS_FILE" <<'PY'
import base64, json, sys
reality = dict(port=443,uuid='00000000-0000-4000-8000-000000000001',public_key='PublicKey',
               private_key='PRIVATE-NO-EXPORT',short_id='00123456',sni='Sni.example',security_mode='reality')
xray = dict(reality,transport='raw',encryption='none',users=[
    dict(name=name,uuid=f'00000000-0000-4000-8000-{i:012d}',enabled=True)
    for i,name in enumerate(['alice','ALICE','LongUserNameOne','LongUserNameTwo'],10)])
singbox = {'vless-singbox':reality}
for p, port in [('hy2',40001),('tuic',40002),('anytls',40003),('naive',40004),('ss2022',40005),
                ('ss-legacy',40006),('socks',40007),('ss2022-shadowtls',40008),('snell-v5',40009),('snell-v6-singbox',40010)]:
    singbox[p]=dict(port=port,uuid='MixedUuid',password='MixedPassword',username='MixedUser',
                   method='aes-128-gcm',psk='MixedSnellPsk1234',version=(5 if p=='snell-v5' else 6),
                   sni='Sni.example',domain='v4.example',stls_password='MixedShadowPassword')
json.dump(dict(singbox=singbox,xray={'vless':xray},snell={'snell-v6':dict(singbox['snell-v6-singbox'])}),open(sys.argv[1],'w'))
vmess = 'vmess://'+base64.b64encode(json.dumps(dict(v='2',ps='Original long name',add='v4.example',port='443',
    id='MixedVmessID',aid='0',net='tcp',tls='tls')).encode()).decode()
links = [
 'vless://MixedExternalID@192.0.2.2:443?security=reality&type=tcp&pbk=PublicKey&sni=Sni.example#old1',
 'vless://MixedExternalID@192.0.2.3:443?security=reality&type=tcp&pbk=PublicKey&sni=Sni.example#old2',
 'trojan://MixedTrojanPassword@v6.example:8443?sni=Sni.example#old',
 'trojan://MixedTrojanPassword@unknown.example:8443?sni=Sni.example#old',vmess,
 'tuic://MixedID:MixedTUICPassword@192.0.2.4:4443?alpn=h3#old',
 'socks5://MixedUser:MixedPassword@192.0.2.4:1080#old',
 'snell://MixedSnellPassword@192.0.2.4:4444?version=6&mode=unshaped#old']
open(sys.argv[2],'w').write('\n'.join(links)+'\n')
PY
head -n 1 "$EXTERNAL_LINKS_FILE" >>"$EXTERNAL_LINKS_FILE"
cp "$EXTERNAL_LINKS_FILE" "$TEST_TMP/original-links"
get_sub_uuid() { printf 'test-subscription\n'; }
generate_sub_files >"$TEST_TMP/generation" 2>"$TEST_TMP/generation-stderr"
cp "$TEST_TMP/country-queries" "$TEST_TMP/batch-country-queries"
cp "$TEST_TMP/dns-queries" "$TEST_TMP/batch-dns-queries"
cmp "$EXTERNAL_LINKS_FILE" "$TEST_TMP/original-links" || fail 'export rewrote imported links'
_build_share_catalog >"$TEST_TMP/catalog"
python3 - "$EXTERNAL_LINKS_FILE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text('\n'.join(reversed(p.read_text().splitlines()))+'\n')
PY
_build_share_catalog >"$TEST_TMP/reversed-catalog"
_gen_user_share_link xray vless 00000000-0000-4000-8000-000000000010 alice >"$TEST_TMP/user"
show_single_protocol_info vless false 443 >"$TEST_TMP/details" 2>"$TEST_TMP/details-stderr"
regenerate_xray_protocol_join_info vless
regenerate_singbox_protocol_join_info socks
cp "$CFG/vless.join" "$TEST_TMP/xray-join"
cp "$CFG/socks.join" "$TEST_TMP/socks-join"
python3 - "$TEST_TMP" "$CFG/subscription/test-subscription" <<'PY'
import base64,collections,json,pathlib,re,sys
from urllib.parse import unquote,urlsplit
root,sub=map(pathlib.Path,sys.argv[1:]); catalog=json.loads((root/'catalog').read_text())
assert catalog==json.loads((root/'reversed-catalog').read_text()), 'naming depends on import order'
names=[n['name'] for n in catalog]
assert len(names)==len(set(names))
assert all(n==n.upper() for n in names),names
assert '🇯🇵 REALITY-443-ALICE' in names and '🇯🇵 REALITY-443-ALICE-1' in names,names
assert '🇯🇵 REALITY-443-LONGUSERNAME' in names and '🇯🇵 REALITY-443-LONGUSERNAME-1' in names,names
assert '🇯🇵 SNELL6-40010-SB' in names and '🇯🇵 SNELL6-40010-OFFICIAL' in names,names
assert '🇸🇬 TROJAN-8443' in names and '🌐 TROJAN-8443' in names,names
for label in ['HY2','TUIC','ANYTLS','NAIVE','SS2022','SS','SOCKS5','SHADOWTLS','SNELL5','SNELL6','VMESS']:
    assert any(n.startswith('🇯🇵 '+label+'-') for n in names),(label,names)
# The file generation builds one catalog and reuses geography across all three formats.
first_batch=(root/'batch-country-queries').read_text().splitlines()
assert first_batch==['192.0.2.1','192.0.2.2','192.0.2.2','192.0.2.3','2001:db8::2','192.0.2.4'],first_batch
# Geography and DNS are reused for each server across all three output formats.
generic=base64.b64decode((sub/'base64').read_bytes()).decode().splitlines()
link_names=[]
for line in generic:
    u=urlsplit(line)
    if u.scheme=='vmess':
        data=json.loads(base64.b64decode(line.removeprefix('vmess://')))
        name=data['ps'];assert data['id']=='MixedVmessID',data
    else:
        name=unquote(u.fragment)
        if u.scheme=='socks5':
            assert u.username=='MixedUser' and u.password=='MixedPassword',line
        if u.scheme=='tuic' and u.port==4443:assert u.password=='MixedTUICPassword',line
        if u.scheme=='snell' and u.port==4444:assert u.username=='MixedSnellPassword',line
        if u.scheme=='trojan':assert u.username=='MixedTrojanPassword',line
    link_names.append(name)
assert len(link_names)==len(set(link_names))==len(catalog),(link_names,names)
assert set(link_names)==set(names)
surge=(sub/'surge.conf').read_text();clash=(sub/'clash.yaml').read_text()
surge_rows=surge.split('[Proxy]\n',1)[1].split('[Proxy Group]',1)[0].splitlines()
surge_names=[line.split(' = ',1)[0] for line in surge_rows if ' = ' in line]
clash_names=[json.loads(line.split('name: ',1)[1]) for line in clash.split('proxy-groups:',1)[0].splitlines() if line.startswith('  - name: ')]
assert set(surge_names)<=set(names) and set(clash_names)<=set(names),(surge_names,clash_names,names)
assert len(surge_names)==len(set(surge_names)) and len(clash_names)==len(set(clash_names))
assert all(name in surge for name in surge_names)
for f in ['user','details','xray-join','socks-join']:
    content=(root/f).read_text()
    assert 'PRIVATE-NO-EXPORT' not in content and 'decryption=' not in content,content
user=urlsplit((root/'user').read_text().strip())
assert unquote(user.fragment)=='🇯🇵 REALITY-443-ALICE-1',user
assert (root/'user').read_text().strip() in (root/'details').read_text()
for f in ['xray-join','socks-join']:
    for line in (root/f).read_text().splitlines():
        if line.startswith(('VLESS_V4=','SOCKS_V4=')):
            assert unquote(urlsplit(line.split('=',1)[1]).fragment) in names,line
PY
printf 'ok - uppercase emoji names, collisions, external renaming, shared formats, user/JOIN consistency\n'
