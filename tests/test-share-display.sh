#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Capture the exact QR payload: links must not include formatting or newlines.
qrencode() {
    local payload
    payload=$(cat; printf '.')
    payload=${payload%.}
    [[ "$payload" != *$'\n'* ]] || fail 'newline in QR payload'
    printf '%s\n' "$payload" >>"$TEST_TMP/qr-input"
    printf '[mock QR]\n'
}
cat >"$DB_FILE" <<'JSON'
{"singbox":{
  "ss-legacy":[
    {"port":44001,"method":"aes-128-gcm","password":"disabled-secret","users":[
      {"name":"disabled","password":"disabled-secret","enabled":false},
      {"name":"active","password":"active-secret","enabled":true}]},
    {"port":44002,"method":"aes-128-gcm","password":"second-secret"}],
  "snell-v6-singbox":{"port":44006,"psk":"test-snell-key","version":6,"mode":"unshaped","tfo":false},
  "ss2022-shadowtls":{"port":44007,"method":"2022-blake3-aes-128-gcm","password":"test-ss-key","stls_password":"test-shadow-key","sni":"example.com"}
}}
JSON
show_single_protocol_info ss-legacy false 44001 >"$TEST_TMP/selected"
grep -q 'Surge 节点配置' "$TEST_TMP/selected" || fail 'Surge section missing'
grep -q 'password=active-secret' "$TEST_TMP/selected" || fail 'active Surge user missing'
if grep -Eq 'disabled-secret|44002' "$TEST_TMP/selected"; then fail 'unselected/disabled credentials shown'; fi
[[ $(wc -l <"$TEST_TMP/qr-input") -eq 1 ]] || fail 'expected one QR for active user'
grep -qx 'ss://.*@192.0.2.1:44001#.*' "$TEST_TMP/qr-input" || fail 'incorrect node QR payload'

show_all_share_links >"$TEST_TMP/all"
grep -q 'password=second-secret' "$TEST_TMP/all" || fail 'second port missing'
grep -q 'version=6, mode=unshaped, reuse=true, tfo=false' "$TEST_TMP/all" || fail 'Snell parameters lost'
grep -q 'shadow-tls-password=test-shadow-key' "$TEST_TMP/all" || fail 'ShadowTLS configuration missing'
printf 'ok - share display includes QR and Surge configurations with port/user filtering\n'

get_connection_addresses() { printf '|2001:db8::1\n'; }
show_single_protocol_info ss-legacy false 44002 >"$TEST_TMP/ipv6-share"
grep -q '@\[2001:db8::1\]:44002' "$TEST_TMP/ipv6-share" || fail 'IPv6 node URI invalid'
grep -q 'ss, \[2001:db8::1\], 44002,' "$TEST_TMP/ipv6-share" || fail 'IPv6 Surge address invalid'

for subscription_https in true false; do
    _write_sub_info 00000000-0000-4000-8000-000000000001 8443 '' "$subscription_https"
    : >"$TEST_TMP/qr-input"
    show_sub_links >"$TEST_TMP/subscriptions"
    subscription_scheme=http
    [[ "$subscription_https" != true ]] || subscription_scheme=https
    for format in clash surge v2ray; do
        expected="${subscription_scheme}://[2001:db8::1]:8443/sub/00000000-0000-4000-8000-000000000001/$format"
        grep -Fxq "$expected" "$TEST_TMP/qr-input" || fail "missing $format subscription QR"
    done
    [[ $(wc -l <"$TEST_TMP/qr-input") -eq 3 ]] || fail 'expected three subscription QRs'
done
printf 'ok - IPv6 node shares and HTTP/HTTPS subscription QR payloads\n'

(
    command() {
        if [[ "$1" == -v && "${2:-}" == qrencode ]]; then return 1; fi
        builtin command "$@"
    }
    show_single_protocol_info ss-legacy false 44002 >"$TEST_TMP/no-qr"
    show_sub_links >>"$TEST_TMP/no-qr"
)
grep -q '需安装 qrencode' "$TEST_TMP/no-qr" || fail 'missing QR installation hint'
grep -q 'password=second-secret' "$TEST_TMP/no-qr" || fail 'missing tool interrupted Surge display'
(
    qrencode() { return 1; }
    show_single_protocol_info ss-legacy false 44002 >"$TEST_TMP/failed-qr"
)
grep -q '二维码生成失败' "$TEST_TMP/failed-qr" || fail 'QR failure not explained'
grep -q 'password=second-secret' "$TEST_TMP/failed-qr" || fail 'QR failure interrupted Surge display'
printf 'ok - unavailable or failing QR tool leaves share display usable\n'
