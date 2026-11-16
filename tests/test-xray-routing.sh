#!/usr/bin/env bash
# All network, services, rules and credentials are local temporary fixtures.
# Set SING_TEST_XRAY_BIN to an official XTLS binary for real DAT/config checks.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { printf '%s\n' "$*" >>"$TEST_TMP/errors"; }
_warn() { printf '%s\n' "$*" >>"$TEST_TMP/warnings"; }
init_db
mkdir -p "$TEST_TMP/releases"
# Minimal protobuf GeoSiteList/GeoIPList fixtures. Production never builds DAT.
python3 - "$TEST_TMP/releases" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
def field(number, payload):
    assert len(payload) < 128
    return bytes([number * 8 + 2, len(payload)]) + payload
for version in ('good', 'missing', 'missing-ip', 'broken'):
    directory = root / version
    directory.mkdir()
    sites = ['category-ai-!cn', 'youtube', 'google', 'twitter', 'cn']
    if version == 'missing':
        sites.remove('youtube')
    site = b''.join(field(1, field(1, tag.upper().encode()) +
        field(2, b'\x08\x02' + field(2, (tag + '.example').encode()))) for tag in sites)
    ips = ['twitter', 'cn'] if version != 'missing-ip' else ['cn']
    ip = b''.join(field(1, field(1, tag.upper().encode()) + b''.join(field(2,
        field(1, address) + b'\x10' + bytes([prefix]))
        for address, prefix in [(bytes([192, 0, 2, 0]), 24), (bytes.fromhex('20010db8000000000000000000000000'), 32)])) for tag in ips)
    if version == 'broken':
        site = b'corrupt DAT fixture'
    for name, content in [('geosite.dat', site), ('geoip.dat', ip)]:
        (directory / name).write_bytes(content)
        (directory / (name + '.sha256sum')).write_text(hashlib.sha256(content).hexdigest() + '  ' + name + '\n')
PY
DOWNLOAD_FAILURE=false
BAD_CHECKSUM=false
RELEASE=good
FAIL_CHECK=false
FAIL_RESTART=''
FAIL_CREATE=false
SINGBOX_RUNNING=false
XRAY_RUNNING=false
svc() {
    local running
    case "$2" in sing-xray) running="$XRAY_RUNNING" ;; sing-singbox) running="$SINGBOX_RUNNING" ;; *) forbidden svc "$@" ;; esac
    case "$1" in
        status) [[ "$running" == true ]]; return ;;
        enabled) return 1 ;;
    esac
    printf '%s:%s\n' "$1" "$2" >>"$TEST_TMP/services"
    case "$1" in
        stop) running=false ;;
        start|restart)
            running=true
            if [[ "$1:$2" == "$FAIL_RESTART" ]]; then
                FAIL_RESTART=''
                if [[ "$2" == sing-xray ]]; then XRAY_RUNNING=false; else SINGBOX_RUNNING=false; fi
                return 1
            fi ;;
        enable|disable) return 0 ;;
        *) forbidden svc "$@" ;;
    esac
    if [[ "$2" == sing-xray ]]; then XRAY_RUNNING="$running"; else SINGBOX_RUNNING="$running"; fi
}
create_xray_service() {
    printf 'candidate service\n' >"$SYSTEMD_DIR/sing-xray.service"
    [[ "$FAIL_CREATE" != true ]]
}
systemctl() { [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"; }
_wait_for_owned_service() { [[ "$1" == sing-xray && "$XRAY_RUNNING" == true ]]; }
_wait_for_singbox_ready() { [[ "$SINGBOX_RUNNING" == true ]]; }
warp-cli() { :; }
curl() {
    local output='' url='' argument
    printf '%s\n' "$*" >>"$TEST_TMP/downloads"
    [[ "$DOWNLOAD_FAILURE" != true ]] || return 1
    while (($#)); do
        argument="$1"; shift
        case "$argument" in
            -o) output="$1"; shift ;;
            https://*) url="$argument" ;;
        esac
    done
    case "$url" in
        https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases/latest)
            printf '{"tag_name":"%s"}\n' "$RELEASE" ;;
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$RELEASE/"*)
            cp "$TEST_TMP/releases/$RELEASE/${url##*/}" "$output"
            if [[ "$BAD_CHECKSUM" == true && "$url" == */geosite.dat ]]; then printf 'bad checksum\n' >>"$output"; fi ;;
        *) forbidden curl "$url" ;;
    esac
}
xray() {
    [[ "$1 $2 $3 $4 $5" == 'run -test -format json -c' && $# == 6 ]] || forbidden xray "$@"
    jq empty "$6" || return 1
    if jq -e 'has("routing")' "$6" >/dev/null; then
        [[ -d "$XRAY_LOCATION_ASSET" ]] || fail 'missing Xray asset environment'
        if [[ "$6" == */.xray-dat-check.*/config.json && -z "${SING_TEST_XRAY_BIN:-}" ]]; then
            cmp -s "$XRAY_LOCATION_ASSET/geosite.dat" "$TEST_TMP/releases/good/geosite.dat" || return 1
            cmp -s "$XRAY_LOCATION_ASSET/geoip.dat" "$TEST_TMP/releases/good/geoip.dat" || return 1
        elif [[ "$FAIL_CHECK" == true ]]; then return 1; fi
    fi
    if [[ -n "${SING_TEST_XRAY_BIN:-}" ]]; then "$SING_TEST_XRAY_BIN" "$@" || return 1; fi
}
raw='{"port":49101,"uuid":"00000000-0000-4000-8000-000000000001","security_mode":"reality","transport":"raw","sni":"test.example","private_key":"eCtXsJZ27-4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU","public_key":"Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo","short_id":"00123456","encryption":"none","decryption":"none"}'
jq -n --argjson raw "$raw" '{xray:{vless:$raw},singbox:{},snell:{},routing:{warp_mode:"disabled"},
    routing_rules:[{type:"google",outbound:"warp",routing_priority:{singbox:0}}]}' >"$DB_FILE"
generate_xray_config
assert_json '.outbounds == [{protocol:"freedom",tag:"direct"}] and (has("routing") | not)' "$CFG/xray.json"
[[ ! -e "$TEST_TMP/downloads" && ! -e "$CFG/xray-rules" ]] || fail 'direct-only Xray fetched rules'
rules='[{"type":"cn","outbound":"direct"},{"type":"google","outbound":"block"},{"type":"twitter","outbound":"direct"},{"type":"youtube","outbound":"direct"},{"type":"ai","outbound":"direct"}]'
rewrite_db ".xray_routing_rules=$rules"
generate_xray_config
assert_json '.routing.domainStrategy == "IPOnDemand" and .dns.servers == ["localhost"] and
    [.routing.rules[].domain[]?] == ["geosite:category-ai-!cn","geosite:youtube","geosite:twitter","geosite:google","geosite:cn"] and
    [.routing.rules[].ip[]?] == ["geoip:twitter","geoip:cn"] and
    all(.routing.rules[:5][]; has("ip") | not) and all(.routing.rules[5:][]; has("domain") | not) and
    all(.inbounds[]; .sniffing == {enabled:true,destOverride:["http","tls","quic"],routeOnly:true}) and
    .outbounds[0] == {protocol:"freedom",tag:"direct"} and
    .routing.rules[4].outboundTag == "direct" and .routing.rules[6].outboundTag == "direct"' "$CFG/xray.json"
[[ -L "$CFG/xray-rules" && "$(stat -c %a "$CFG/xray-rules/geosite.dat")" == 600 ]] || fail 'rule publication/permissions'
[[ "$(stat -c %a "$(readlink "$CFG/xray-rules")")" == 700 ]] || fail 'private rule directory'
rules=$(db_get_xray_routing_rules)
if _move_xray_routing_rule "$rules" 4 1; then fail 'Google moved ahead of AI/YouTube'; fi
grep -q 'AI、YouTube 必须排在 Google 前面' "$TEST_TMP/errors" || fail 'missing Chinese order explanation'
next=$(_move_xray_routing_rule "$rules" 3 1)
_apply_xray_routing_rules "$next"
assert_json '[.routing.rules[:5][].domain[0]] == ["geosite:twitter","geosite:category-ai-!cn","geosite:youtube","geosite:google","geosite:cn"]' "$CFG/xray.json"
assert_json '.routing_rules == [{type:"google",outbound:"warp",routing_priority:{singbox:0}}]' "$DB_FILE"
printf 'ok - five tags, global domain/IP phases, ordering constraints, sniffing, dual stack and independent direct fallback\n'

save_state() {
    cp -p "$DB_FILE" "$TEST_TMP/previous-db"
    cp -p "$CFG/xray.json" "$TEST_TMP/previous-config"
    readlink "$CFG/xray-rules" >"$TEST_TMP/previous-link"
}
assert_state() {
    cmp "$DB_FILE" "$TEST_TMP/previous-db" || fail 'DB rollback'
    cmp "$CFG/xray.json" "$TEST_TMP/previous-config" || fail 'config rollback'
    [[ "$(readlink "$CFG/xray-rules")" == "$(cat "$TEST_TMP/previous-link")" ]] || fail 'DAT pointer rollback'
}
save_state
XRAY_RUNNING=true
(
    mv() {
        if [[ "${@: -1}" == "$CFG/xray.json" && "$2" == */candidate.json ]]; then return 1; fi
        command mv "$@"
    }
    if update_xray_rules; then fail 'config rename failure committed resources'; fi
    assert_state
)
FAIL_RESTART=restart:sing-xray
if update_xray_rules; then fail 'restart failure committed new resources'; fi
assert_state
[[ "$XRAY_RUNNING" == true ]] || fail 'running service not restored'
for failure in check create; do
    FAIL_CHECK=false; FAIL_CREATE=false
    if [[ "$failure" == check ]]; then FAIL_CHECK=true; else FAIL_CREATE=true; fi
    if update_xray_rules; then fail "$failure failure committed"; fi
    assert_state
done
FAIL_CHECK=false; FAIL_CREATE=false
XRAY_RUNNING=false
: >"$TEST_TMP/services"
update_xray_rules
[[ "$XRAY_RUNNING" == false && ! -s "$TEST_TMP/services" ]] || fail 'stopped service activated'
[[ "$(readlink "$CFG/xray-rules")" != "$(cat "$TEST_TMP/previous-link")" ]] || fail 'manual update did not switch resources'
printf 'ok - resource/DB/config rollback on check, service-file and restart failures; stopped service stays stopped\n'

save_state
for failure in download checksum missing missing-ip broken; do
    DOWNLOAD_FAILURE=false; BAD_CHECKSUM=false; RELEASE=good
    case "$failure" in download) DOWNLOAD_FAILURE=true ;; checksum) BAD_CHECKSUM=true ;; *) RELEASE="$failure" ;; esac
    if update_xray_rules; then fail "$failure DAT accepted"; fi
    assert_state
done
RELEASE=good; BAD_CHECKSUM=false
# Automatic refresh may use verified old DAT; manual update must report failure.
printf '{"installed_at":0}\n' >"$CFG/xray-rules/release.json"
DOWNLOAD_FAILURE=true
generate_xray_config
grep -q '继续使用已校验的旧规则' "$TEST_TMP/warnings" || fail 'silent automatic fallback'
printf 'corrupted old rules\n' >>"$CFG/xray-rules/geosite.dat"
cp "$CFG/xray.json" "$TEST_TMP/previous-config"
if generate_xray_config; then fail 'corrupt old DAT used as fallback'; fi
cmp "$CFG/xray.json" "$TEST_TMP/previous-config"
rm "$CFG/xray-rules"
if generate_xray_config; then fail 'first download failure accepted'; fi
DOWNLOAD_FAILURE=false
generate_xray_config
printf 'ok - same-release checksum checks, corrupt/missing-category DAT rejection, first-download failure and validated automatic fallback\n'

# Exercise every supported native chain protocol with the real configuration generator.
python3 - "$DB_FILE" <<'PY'
import json, sys
path = sys.argv[1]
db = json.load(open(path))
base = dict(server='192.0.2.2', port=443)
nodes = [dict(base, name='socks', type='socks', username='test-user', password='test-pass'),
    dict(base, name='http', type='http', username='test-user', password='test-pass', security='tls', sni='proxy.example'),
    dict(base, name='ss', type='shadowsocks', method='aes-128-gcm', password='test-pass'),
    dict(base, name='vmess', type='vmess', uuid='00000000-0000-4000-8000-000000000002', alterId=0, cipher='auto',
        tls='tls', network='ws', wsPath='/test', wsHost='proxy.example'),
    dict(base, name='vless', type='vless', uuid='00000000-0000-4000-8000-000000000002', security='reality',
        publicKey='Cr8hWlKvtDt7nrvf-f0brNQQzabAqrjfBvas9pmowjo', shortId='0001', sni='proxy.example',
        fingerprint='chrome', encryption='none', flow='xtls-rprx-vision', network='tcp'),
    dict(base, name='trojan', type='trojan', password='test-pass', network='grpc', serviceName='test-grpc', sni='proxy.example')]
db['chain_proxy'] = dict(nodes=nodes)
json.dump(db, open(path, 'w'))
PY
for name in socks http ss vmess vless trojan; do
    _apply_xray_routing_rules "[{\"type\":\"ai\",\"outbound\":\"chain:$name\"}]"
    jq -e --arg tag "chain-$name" 'any(.outbounds[]; .tag == $tag) and .routing.rules[0].outboundTag == $tag' "$CFG/xray.json" >/dev/null || fail 'missing native chain'
done
gen_xray_chain_outbound vless >"$TEST_TMP/vless-outbound.json"
assert_json '.settings.vnext[0].users[0].flow == "xtls-rprx-vision" and .streamSettings.realitySettings.shortId == "0001"' "$TEST_TMP/vless-outbound.json"
gen_xray_chain_outbound vmess >"$TEST_TMP/vmess-outbound.json"
assert_json '.streamSettings.wsSettings == {path:"/test",headers:{Host:"proxy.example"}}' "$TEST_TMP/vmess-outbound.json"
save_state
if _apply_xray_routing_rules '[{"type":"ai","outbound":"chain:missing"}]'; then fail 'missing chain accepted'; fi
assert_state
cp "$DB_FILE" "$TEST_TMP/chain-db"
for mutation in '.chain_proxy.nodes[5].type="hysteria2"' '.chain_proxy.nodes[5].extra={}' \
    '.chain_proxy.nodes[5].network="xhttp"' '.chain_proxy.nodes[5].plugin="test-plugin"' \
    '.chain_proxy.nodes[5].security="unknown"'; do
    jq "$mutation" "$TEST_TMP/chain-db" >"$DB_FILE"
    if gen_xray_chain_outbound trojan; then fail "unsupported node accepted: $mutation"; fi
done
cp "$TEST_TMP/chain-db" "$DB_FILE"
XRAY_RUNNING=true
FAIL_RESTART=restart:sing-xray
if db_rename_chain_node trojan renamed; then fail 'failed node rename committed'; fi
assert_state
[[ "$XRAY_RUNNING" == true ]] || fail 'node rename did not restore running service'
XRAY_RUNNING=false
db_rename_chain_node trojan renamed
assert_json '.xray_routing_rules[0].outbound == "chain:renamed"' "$DB_FILE"
assert_json 'any(.outbounds[]; .tag == "chain-renamed")' "$CFG/xray.json"
db_del_chain_node renamed
assert_json '.xray_routing_rules == []' "$DB_FILE"
assert_json '.outbounds == [{protocol:"freedom",tag:"direct"}] and (has("routing") | not)' "$CFG/xray.json"
printf 'ok - six native chain protocols, authentication/TLS/REALITY/flow/transport, missing/unsupported nodes, rename/delete and Xray-only installation\n'

db_set_warp_mode official
_apply_xray_routing_rules '[{"type":"ai","outbound":"warp"}]'
assert_json 'any(.outbounds[]; .tag == "warp" and .protocol == "socks" and .settings.servers[0] == {address:"127.0.0.1",port:40000})' "$CFG/xray.json"
jq -n '{private_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE=",public_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI=",
    address_v4:"172.16.0.2/32",address_v6:"2606:4700:110:1234::2/128",endpoint:"[2606:4700:d0::a29f:c001]:2408",reserved:[1,2,3]}' >"$WARP_CONF_FILE"
db_set_warp_mode wgcf
assert_json 'any(.outbounds[]; .tag == "warp" and .protocol == "wireguard" and .settings.noKernelTun == true and
    .settings.address == ["172.16.0.2/32","2606:4700:110:1234::2/128"] and .settings.reserved == [1,2,3])' "$CFG/xray.json"
save_state
if db_set_warp_mode disabled; then fail 'missing WARP accepted'; fi
assert_state
# Core update rollback includes DAT even when the config bytes have not changed.
mkdir -p "$CFG/bin"
printf 'owned core fixture\n' >"$CFG/bin/xray"
refresh_then_fail() {
    local XRAY_RULES_FORCE_UPDATE=true
    generate_xray_config || return 1
    return 1
}
if _update_xray_core_to_version stable 26.11.9 refresh_then_fail; then fail 'failed upgrade committed resources'; fi
assert_state
refresh_installer() { local XRAY_RULES_FORCE_UPDATE=true; generate_xray_config; }
XRAY_RUNNING=true
FAIL_RESTART=restart:sing-xray
if _update_xray_core_to_version stable 26.11.9 refresh_installer; then fail 'upgrade restart failure committed resources'; fi
assert_state
[[ "$XRAY_RUNNING" == true ]] || fail 'upgrade failed to restore running state'
XRAY_RUNNING=false
printf 'ok - official SOCKS and native userspace WGCF WARP modes; missing WARP rejects atomically\n'

# One shared exit change affects both cores; mock both services, use real generators.
rewrite_db '.singbox.socks={port:49102,auth_mode:"noauth"} | .routing_rules=[]'
generate_singbox_config
SINGBOX_RUNNING=true; XRAY_RUNNING=true
save_state
cp "$CFG/singbox.json" "$TEST_TMP/previous-singbox"
cp "$WARP_CONF_FILE" "$TEST_TMP/previous-warp"
FAIL_RESTART=restart:sing-xray
if db_set_warp_mode official; then fail 'partial two-core update committed'; fi
assert_state
cmp "$CFG/singbox.json" "$TEST_TMP/previous-singbox"
cmp "$WARP_CONF_FILE" "$TEST_TMP/previous-warp"
[[ "$SINGBOX_RUNNING" == true && "$XRAY_RUNNING" == true ]] || fail 'two-core service rollback'
# Changing the shared WGCF account must restore the account bytes as well.
jq '.endpoint="192.0.2.99:2408"' "$WARP_CONF_FILE" >"$TEST_TMP/new-warp"
FAIL_RESTART=restart:sing-xray
if SHARED_WARP_CANDIDATE="$TEST_TMP/new-warp" _apply_shared_routing_change '.routing.warp_mode="wgcf"'; then fail 'failed WGCF account change committed'; fi
assert_state
cmp "$CFG/singbox.json" "$TEST_TMP/previous-singbox"
cmp "$WARP_CONF_FILE" "$TEST_TMP/previous-warp"
SINGBOX_RUNNING=false; XRAY_RUNNING=false
db_set_warp_mode official
[[ "$SINGBOX_RUNNING" == false && "$XRAY_RUNNING" == false ]] || fail 'shared change activated stopped service'
printf 'ok - shared WARP changes roll back both cores and preserve both stopped states\n'

# Menu edits use the real transaction immediately, including rollback and redraw.
(
    _item() { printf '  [%s] %s\n' "$1" "$2"; }
    _line() { :; }
    _ok() { printf '%s\n' "$*" >>"$TEST_TMP/menu-success"; }
    _apply_xray_routing_rules '[]'
    cp "$CFG/singbox.json" "$TEST_TMP/menu-singbox"
    : >"$TEST_TMP/services"
    # Select AI, then chain node 1; returning must retain the completed change.
    configure_xray_routing_rules <<< $'1\n1\n4\n1\n0' >"$TEST_TMP/menu-set"
    assert_json '.xray_routing_rules == [{type:"ai",outbound:"chain:socks",order:0}]' "$DB_FILE"
    assert_json '.routing.rules[0].outboundTag == "chain-socks"' "$CFG/xray.json"
    grep -q 'AI → socks' "$TEST_TMP/menu-set" || fail 'menu did not redraw saved rule'
    if grep -qE '应用配置|未应用|放弃' "$TEST_TMP/menu-set"; then fail 'menu still requires a separate apply'; fi
    [[ "$XRAY_RUNNING" == false && ! -s "$TEST_TMP/services" ]] || fail 'menu started stopped Xray'
    configure_xray_routing_rules <<< $'1\n1\n2\n0' >"$TEST_TMP/menu-replace"
    assert_json '.xray_routing_rules[0].outbound == "block"' "$DB_FILE"
    assert_json '.routing.rules[0].outboundTag == "block"' "$CFG/xray.json"
    configure_xray_routing_rules <<< $'1\n2\n1\n1\n3\n1\n0' >"$TEST_TMP/menu-add"
    assert_json '[.xray_routing_rules[].type] == ["ai","youtube","twitter"]' "$DB_FILE"
    configure_xray_routing_rules <<< $'3\n3\n1\n0' >"$TEST_TMP/menu-order"
    assert_json '[.xray_routing_rules[].type] == ["twitter","ai","youtube"]' "$DB_FILE"
    assert_json '[.routing.rules[:3][].domain[0]] == ["geosite:twitter","geosite:category-ai-!cn","geosite:youtube"]' "$CFG/xray.json"

    XRAY_RUNNING=true
    save_state
    # A failed set/delete/reorder must redraw persisted rules, without success.
    for failure in check restart; do
        for input in $'1\n3\n2\n0' $'2\n1\n0' $'3\n1\n3\n0'; do
            : >"$TEST_TMP/menu-success"
            case "$failure" in check) FAIL_CHECK=true ;; restart) FAIL_RESTART=restart:sing-xray ;; esac
            configure_xray_routing_rules <<<"$input" >"$TEST_TMP/menu-failure"
            FAIL_CHECK=false
            assert_state
            [[ "$XRAY_RUNNING" == true && ! -s "$TEST_TMP/menu-success" ]] || fail 'failed menu edit reported success or lost runtime'
            tail -n 9 "$TEST_TMP/menu-failure" >"$TEST_TMP/menu-redraw"
            grep -q 'X → 直连' "$TEST_TMP/menu-redraw" || fail 'failed menu edit displayed uncommitted rules'
        done
    done
    XRAY_RUNNING=false
    : >"$TEST_TMP/services"
    # Cancellation, invalid input and EOF never reach the transaction.
    for input in $'1\n0\n0' $'1\n1\n0\n0' $'1\n1\n4\n0\n0' $'2\n0\n0' \
        $'2\n99\n0' $'3\n0\n0' $'3\n1\n0\n0'; do
        configure_xray_routing_rules <<<"$input" >"$TEST_TMP/menu-cancel"
        assert_state
    done
    if configure_xray_routing_rules <<< $'1\n1' >"$TEST_TMP/menu-eof"; then :; fi
    assert_state
    [[ ! -s "$TEST_TMP/services" ]] || fail 'cancelled menu edit touched service'
    configure_xray_routing_rules <<< $'1\n4\n1\n0' >"$TEST_TMP/menu-google"
    save_state
    configure_xray_routing_rules <<< $'3\n4\n1\n0' >"$TEST_TMP/menu-invalid-order"
    assert_state

    previous_link=$(readlink "$CFG/xray-rules")
    configure_xray_routing_rules <<< $'4\n0' >"$TEST_TMP/menu-update"
    [[ "$(readlink "$CFG/xray-rules")" != "$previous_link" ]] || fail 'menu rule update did not publish resources'
    # Removing the final rule immediately restores the default direct config.
    XRAY_RUNNING=true
    configure_xray_routing_rules <<< $'2\n1\n2\n1\n2\n1\n2\n1\n0' >"$TEST_TMP/menu-delete"
    assert_json '.xray_routing_rules == []' "$DB_FILE"
    assert_json '.outbounds == [{protocol:"freedom",tag:"direct"}] and (has("routing") | not)' "$CFG/xray.json"
    cmp "$CFG/singbox.json" "$TEST_TMP/menu-singbox" || fail 'Xray menu changed Sing-box config'
    [[ "$XRAY_RUNNING" == true ]] || fail 'successful menu edits stopped Xray'
)
printf 'ok - menu sets, replaces, deletes and reorders immediately; failures/cancellation preserve persisted rules and runtime\n'

# Each UI dispatches directly on a single-core installation.
(
    configure_xray_routing_rules() { printf 'xray\n' >>"$TEST_TMP/menu"; }
    configure_singbox_routing_rules() { printf 'singbox\n' >>"$TEST_TMP/menu"; }
    rewrite_db '.singbox={}'
    configure_routing_rules </dev/null
    rewrite_db '.singbox.socks={port:49102}'
    configure_routing_rules <<<2
    configure_routing_rules <<<1
    [[ "$(cat "$TEST_TMP/menu")" == $'xray\nxray\nsingbox' ]] || fail 'routing core menu dispatch'
)
[[ -z "${DB_LOCK_FD:-}" ]] || fail 'routing transaction leaked lock'
if compgen -G "$CFG/.xray-dat-check.*" >/dev/null || compgen -G "$CFG/.shared-routing.*" >/dev/null; then fail 'temporary transaction leaked'; fi
printf 'ok - per-core menu dispatch and temporary transaction cleanup\n'
