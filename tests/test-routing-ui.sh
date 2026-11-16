#!/usr/bin/env bash
# Exercise real menu dispatch and rendering with temporary data and mocked cores.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_header() { fail 'routing page used the full application banner'; }
_item() { printf '  [%s] %s\n' "$1" "$2"; }
_line() { printf '  ────────────────────\n'; }
_err() { printf '错误: %s\n' "$*"; }
_warn() { printf '提示: %s\n' "$*"; }
_ok() { printf '%s\n' "$*"; }
assert_text() { rg -Fq -- "$1" "$2" || fail "missing '$1' in ${2##*/}"; }
assert_absent() { if rg -Fq -- "$1" "$2"; then fail "unexpected '$1' in ${2##*/}"; fi; }

cat >"$DB_FILE" <<'JSON'
{
  "singbox":{"socks":{"port":44100}}, "xray":{"vless":{"port":44101}},
  "routing":{"warp_mode":"disabled"},
  "chain_proxy":{"nodes":[{"name":"Verizon","type":"shadowsocks"},{"name":"SB-Node","type":"socks"}]},
  "balancer_groups":[{"name":"pool","strategy":"selector","nodes":["SB-Node"]}],
  "routing_rules":[
    {"id":"g","type":"google","outbound":"chain:SB-Node","ip_version":"as_is","routing_priority":{"singbox":1}},
    {"id":"y","type":"youtube","outbound":"direct","ip_version":"as_is","routing_priority":{"singbox":0}},
    {"id":"t","type":"twitter","outbound":"warp","ip_version":"ipv6_only","routing_priority":{"singbox":2}},
    {"id":"a","type":"ads","outbound":"block","routing_priority":{"singbox":3}}
  ],
  "xray_routing_rules":[{"type":"ai","outbound":"chain:Verizon","order":0}]
}
JSON
cp "$DB_FILE" "$TEST_TMP/original-db"
printf 'prefer_ipv6\n' >"$CFG/direct_ip_version"

show_routing_status singbox >"$TEST_TMP/singbox-status"
show_routing_status xray >"$TEST_TMP/xray-status"
assert_text '直连: 优先 IPv6' "$TEST_TMP/singbox-status"
assert_text '1. YouTube → 直连' "$TEST_TMP/singbox-status"
assert_text '2. Google → SB-Node' "$TEST_TMP/singbox-status"
assert_text '3. X → WARP [仅 IPv6]' "$TEST_TMP/singbox-status"
assert_text '4. 广告屏蔽 → 拦截' "$TEST_TMP/singbox-status"
assert_absent 'Verizon' "$TEST_TMP/singbox-status"
assert_absent '[ALL]' "$TEST_TMP/singbox-status"
assert_text '直连: 系统默认' "$TEST_TMP/xray-status"
assert_text '1. AI → Verizon' "$TEST_TMP/xray-status"
assert_absent 'SB-Node' "$TEST_TMP/xray-status"
assert_absent 'chain:' "$TEST_TMP/xray-status"
_show_routing_rules singbox '[{"type":"custom","domains":"example.test","outbound":"balancer:pool","ip_version":"prefer_ipv4"}]' >"$TEST_TMP/custom"
assert_text '自定义 (example.test) → 负载均衡 (pool) [优先 IPv4]' "$TEST_TMP/custom"
_show_routing_rules xray '[]' >"$TEST_TMP/empty"
assert_text '暂无规则，默认直连' "$TEST_TMP/empty"
(
    ROUTING_ACTIVE_CORE=xray
    _routing_header '选择分流内核' '' >"$TEST_TMP/selector-header"
    assert_absent 'Xray' "$TEST_TMP/selector-header"
)
printf 'ok - routing status isolates cores and uses common readable labels\n'

(
    manage_warp() { printf 'warp:%s\n' "$ROUTING_ACTIVE_CORE" >>"$TEST_TMP/actions"; }
    manage_chain_proxy() { printf 'chain:%s\n' "$ROUTING_ACTIVE_CORE" >>"$TEST_TMP/actions"; }
    configure_singbox_routing_rules() { printf 'rules:singbox\n' >>"$TEST_TMP/actions"; }
    configure_xray_routing_rules() { printf 'rules:xray\n' >>"$TEST_TMP/actions"; }
    test_routing() { printf 'check:%s\n' "$1" >>"$TEST_TMP/actions"; }
    show_runtime_config() { printf 'view:%s\n' "$1" >>"$TEST_TMP/actions"; }
    _manage_routing_options() { printf 'more:%s\n' "$1" >>"$TEST_TMP/actions"; }
    # Unsupported options cannot dispatch; cancelling a switch keeps Xray active.
    manage_routing <<< $'2\n1\n2\n3\n4\n5\n6\n9\n0\n4\n9\n1\n3\n4\n5\n6\n0' >"$TEST_TMP/dual-menu"
    [[ "$(cat "$TEST_TMP/actions")" == $'warp:xray\nchain:xray\nrules:xray\ncheck:xray\nview:xray\ncheck:xray\nrules:singbox\ncheck:singbox\nview:singbox\nmore:singbox' ]] || fail 'active core lost during menu navigation'
    assert_text '分流管理 · Xray' "$TEST_TMP/dual-menu"
    assert_text '分流管理 · sing-box' "$TEST_TMP/dual-menu"
    assert_text '[9] 切换内核' "$TEST_TMP/dual-menu"
    assert_absent 'chain:' "$TEST_TMP/dual-menu"

    for core in xray singbox; do
        cp "$TEST_TMP/original-db" "$DB_FILE"
        if [[ "$core" == xray ]]; then rewrite_db '.singbox={}'
        else rewrite_db '.xray={}'; fi
        : >"$TEST_TMP/actions"
        manage_routing <<< $'3\n4\n5\n9\n0' >"$TEST_TMP/single-$core"
        [[ "$(cat "$TEST_TMP/actions")" == "rules:$core"$'\n'"check:$core"$'\n'"view:$core" ]] || fail "single-core $core dispatch"
        assert_absent '选择分流内核' "$TEST_TMP/single-$core"
        assert_absent '[9]' "$TEST_TMP/single-$core"
    done
    assert_absent '更多设置' "$TEST_TMP/single-xray"
    assert_text '[6] 更多设置' "$TEST_TMP/single-singbox"
    cp "$TEST_TMP/original-db" "$DB_FILE"
    if manage_routing <<<0 >"$TEST_TMP/cancel"; then :; fi
    assert_absent '分流管理 ·' "$TEST_TMP/cancel"
    rewrite_db '.singbox={} | .xray={}'
    if manage_routing </dev/null >"$TEST_TMP/not-installed"; then fail 'empty installation entered routing manager'; fi
)
cp "$TEST_TMP/original-db" "$DB_FILE"
printf 'ok - selection, switching, cancellation and every action retain the active core\n'

(
    gen_xray_chain_outbound() {
        printf 'chain:%s\n' "$1" >>"$TEST_TMP/native-validation"
        [[ "$1" != SB-Node ]] || return 1
        printf '{}\n'
    }
    gen_xray_warp_outbound() { printf 'warp\n' >>"$TEST_TMP/native-validation"; return 1; }
    # The selector assigns through dynamic scope, as the manager does.
    ROUTING_SELECTED_OUTBOUND=''
    XRAY_SELECTED_OUTBOUND=''
    for core in singbox xray; do
        _select_routing_outbound "$core" <<< $'4\n1' >"$TEST_TMP/outbound-$core"
        [[ "$ROUTING_SELECTED_OUTBOUND" == chain:Verizon ]] || fail 'numbered node selection'
        assert_text '[1] 直连' "$TEST_TMP/outbound-$core"
        assert_text '[2] 拦截' "$TEST_TMP/outbound-$core"
        assert_text '[3] WARP' "$TEST_TMP/outbound-$core"
        assert_text '[4] 链式节点' "$TEST_TMP/outbound-$core"
        assert_text '[1] Verizon (shadowsocks)' "$TEST_TMP/outbound-$core"
        assert_absent '输入节点名称' "$TEST_TMP/outbound-$core"
    done
    assert_absent '负载均衡组' "$TEST_TMP/outbound-xray"
    for input in 0 5 $'4\n0' $'4\n99' $'4\n2' 3; do
        if _select_xray_outbound <<<"$input" >"$TEST_TMP/rejected"; then fail 'cancelled/unsupported Xray exit accepted'; fi
        [[ -z "$XRAY_SELECTED_OUTBOUND" ]] || fail 'rejected exit retained previous selection'
    done
    _select_xray_outbound <<< $'4\n1' >"$TEST_TMP/native-node"
    [[ "$XRAY_SELECTED_OUTBOUND" == chain:Verizon ]] || fail 'Xray selection wrapper'
    outbound=$(_select_outbound '选择出口' no_check <<< $'5\n1' 2>"$TEST_TMP/balancer-menu")
    [[ "$outbound" == balancer:pool ]] || fail 'sing-box balancer selection lost'
    outbound=$(_select_outbound '选择出口' no_check <<<2 2>"$TEST_TMP/block-menu")
    [[ "$outbound" == block ]] || fail 'sing-box block selection'
    if _select_outbound '选择出口' no_check </dev/null >"$TEST_TMP/eof" 2>&1; then fail 'EOF selected an outbound'; fi
    warp_status() { printf 'configured\n'; }
    outbound=$(_select_outbound '选择出口' no_check <<<3 2>"$TEST_TMP/warp-menu")
    [[ "$outbound" == warp ]] || fail 'configured WARP cannot be selected'
)
printf 'ok - both cores share numbered exit selection and retain native validation\n'

configure_singbox_routing_rules <<<0 >"$TEST_TMP/singbox-rules"
configure_xray_routing_rules <<<0 >"$TEST_TMP/xray-rules"
for core in singbox xray; do
    assert_text '[1] 设置规则' "$TEST_TMP/$core-rules"
    assert_text '[2] 删除规则' "$TEST_TMP/$core-rules"
    assert_text '[3] 调整顺序' "$TEST_TMP/$core-rules"
    assert_absent '应用配置' "$TEST_TMP/$core-rules"
done
assert_absent 'Verizon' "$TEST_TMP/singbox-rules"
assert_absent 'SB-Node' "$TEST_TMP/xray-rules"
(
    _regenerate_proxy_configs() { printf 'singbox\n' >>"$TEST_TMP/reload"; }
    _del_routing_rule <<<1 >"$TEST_TMP/delete"
    assert_text '1. YouTube → 直连' "$TEST_TMP/delete"
    assert_json 'all(.routing_rules[]; .id != "y") and any(.routing_rules[]; .id == "g") and .xray_routing_rules[0].outbound == "chain:Verizon"' "$DB_FILE"
    [[ "$(cat "$TEST_TMP/reload")" == singbox ]] || fail 'delete reloaded the wrong core'
)
cp "$TEST_TMP/original-db" "$DB_FILE"
_reorder_routing_rules <<<0 >"$TEST_TMP/order"
assert_text '1. YouTube → 直连' "$TEST_TMP/order"
cmp "$TEST_TMP/original-db" "$DB_FILE"
(
    ROUTING_ACTIVE_CORE=xray
    manage_warp <<<0 >"$TEST_TMP/shared-warp"
    manage_chain_proxy <<< $'7\n8\n0' >"$TEST_TMP/shared-chain"
    assert_text 'WARP 管理（共享出口）' "$TEST_TMP/shared-warp"
    assert_text '链式代理（共享出口）' "$TEST_TMP/shared-chain"
    assert_text 'Verizon' "$TEST_TMP/shared-chain"
    assert_text 'AI (Xray)' "$TEST_TMP/shared-chain"
    assert_absent '负载均衡组' "$TEST_TMP/shared-chain"
    assert_absent '多IP' "$TEST_TMP/shared-chain"
    assert_absent '双层链式' "$TEST_TMP/shared-chain"
)
printf 'ok - rule submenus share layout and deletion follows the displayed order\n'

printf '{"outbounds":[{"type":"direct","tag":"direct"}]}\n' >"$CFG/singbox.json"
printf '{"outbounds":[{"protocol":"freedom","tag":"direct"}]}\n' >"$CFG/xray.json"
cp "$CFG/singbox.json" "$TEST_TMP/singbox-before"
cp "$CFG/xray.json" "$TEST_TMP/xray-before"
(
    sing-box() {
        case "$1" in
            version) printf 'sing-box version 1.14.4\n' ;;
            check)
                [[ "$2" == -c && "$3" == "$CFG/singbox.json" ]] || fail 'wrong sing-box check arguments'
                printf 'singbox\n' >>"$TEST_TMP/checks"
                jq empty "$3" ;;
            *) forbidden sing-box "$@" ;;
        esac
    }
    xray() {
        [[ "$*" == "run -test -format json -c $CFG/xray.json" ]] || fail 'wrong Xray check arguments'
        [[ "$XRAY_LOCATION_ASSET" == "$CFG/xray-rules" ]] || fail 'Xray asset path missing'
        printf 'xray\n' >>"$TEST_TMP/checks"
        jq empty "$6"
    }
    _runtime_config_service_pid() { printf '0\n'; }
    for core in singbox xray; do
        test_routing "$core" >"$TEST_TMP/check-$core"
        assert_text '配置检查通过' "$TEST_TMP/check-$core"
        show_runtime_config "$core" >"$TEST_TMP/view-$core"
        assert_text "$CFG/$core.json" "$TEST_TMP/view-$core"
    done
    [[ "$(cat "$TEST_TMP/checks")" == $'singbox\nxray' ]] || fail 'wrong validation core'
    cmp "$TEST_TMP/singbox-before" "$CFG/singbox.json"
    cmp "$TEST_TMP/xray-before" "$CFG/xray.json"
    cmp "$TEST_TMP/original-db" "$DB_FILE"
    printf '{broken' >"$CFG/xray.json"
    if test_routing xray >"$TEST_TMP/invalid-config" 2>&1; then fail 'invalid configuration passed'; fi
    assert_absent '配置检查通过' "$TEST_TMP/invalid-config"
    assert_text '配置检查失败' "$TEST_TMP/invalid-config"
    rm "$CFG/xray.json"
    if test_routing xray >"$TEST_TMP/missing-config"; then fail 'missing configuration passed'; fi
    assert_text '尚未生成配置' "$TEST_TMP/missing-config"
)
cp "$TEST_TMP/xray-before" "$CFG/xray.json"
cmp "$TEST_TMP/singbox-before" "$CFG/singbox.json"
cmp "$TEST_TMP/xray-before" "$CFG/xray.json"
cmp "$TEST_TMP/original-db" "$DB_FILE"
printf 'ok - configuration checks use the selected binary and stay read-only\n'
