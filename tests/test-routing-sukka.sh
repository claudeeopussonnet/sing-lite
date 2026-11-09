#!/usr/bin/env bash
# No live downloads/services. Use the official binary when it is available.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

export SUKKA_TEST_FIXTURES="$TEST_TMP/upstream"
export SUKKA_TEST_DOWNLOADS="$TEST_TMP/downloads"
export SUKKA_TEST_DOWNLOAD_MODE=valid
export SUKKA_TEST_COMPILE_FAIL=false
export SUKKA_TEST_BINARY="${SING_TEST_SINGBOX_BIN:-}"
if [[ -z "$SUKKA_TEST_BINARY" && -x /tmp/sing-lite-sing-box-1.14.4 ]]; then
    export SUKKA_TEST_BINARY=/tmp/sing-lite-sing-box-1.14.4
fi
mkdir -p "$TEST_TMP/bin" "$SUKKA_TEST_FIXTURES"
export PATH="$TEST_TMP/bin:$PATH"

# The production downloader may invoke curl from Python, so a shell function
# alone cannot isolate it. Reject URLs outside the two approved source origins.
cat >"$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -e
url="${@: -1}"
printf '%s\n' "$url" >>"$SUKKA_TEST_DOWNLOADS"
case "$url" in
    https://ruleset.skk.moe/sing-box/*.json) ;;
    https://raw.githubusercontent.com/Yuu518/sing-box-rules/*.json)
        cat "$SUKKA_TEST_FIXTURES/yuu.json"; exit 0 ;;
    *) printf 'unexpected download: %s\n' "$url" >&2; exit 91 ;;
esac
case "$SUKKA_TEST_DOWNLOAD_MODE" in
    invalid) printf '{broken JSON'; exit 0 ;;
    failed) exit 22 ;;
esac
source_name="${url#https://ruleset.skk.moe/sing-box/}"
[[ "$source_name" != *..* && -f "$SUKKA_TEST_FIXTURES/$source_name" ]] || exit 92
cat "$SUKKA_TEST_FIXTURES/$source_name"
SH
cat >"$TEST_TMP/bin/test-sing-box" <<'SH'
#!/usr/bin/env bash
set -e
if [[ "$1 $2" == 'rule-set compile' && "$SUKKA_TEST_COMPILE_FAIL" == true ]]; then
    printf 'partial compiler output' >"$5"
    exit 1
fi
if [[ -n "$SUKKA_TEST_BINARY" ]]; then exec "$SUKKA_TEST_BINARY" "$@"; fi
case "$1 $2" in
    'rule-set compile'|'rule-set decompile') jq -e '.version and (.rules | length > 0)' "$3" >/dev/null; cp "$3" "$5" ;;
    'check -c') jq empty "$3" ;;
    'version ') printf 'sing-box version 1.14.4\n' ;;
    *) exit 93 ;;
esac
SH
chmod 700 "$TEST_TMP/bin/curl" "$TEST_TMP/bin/test-sing-box"
export SINGBOX_CONFIG_BINARY="$TEST_TMP/bin/test-sing-box"
sing-box() { "$SINGBOX_CONFIG_BINARY" "$@"; }
curl() { command curl "$@"; }

python3 - "$SUKKA_TEST_FIXTURES" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
aggregate = {'version': 3, 'rules': [{'domain_suffix': ['native.example', 'also-native.example']} ]}
(root / 'yuu.json').write_text(json.dumps({'version': 2, 'rules': [
    {'domain': ['www.youtube.com'], 'domain_suffix': ['youtube.com', 'google.com']}]}))
for phase, names in {
    'domainset': ['reject', 'cdn'],
    'non_ip': ['stream', 'stream_jp', 'ai', 'telegram', 'reject', 'domestic'],
    'ip': ['ai', 'stream', 'stream_jp', 'telegram', 'reject', 'china_ip', 'china_ip_ipv6'],
}.items():
    for name in names:
        path = root / phase / (name + '.json')
        path.parent.mkdir(exist_ok=True)
        doc = aggregate if phase == 'non_ip' else {'version': 3, 'rules': [
            {'ip_cidr': ['2001:db8::/32' if name.endswith('ipv6') else '192.0.2.0/24']}
            if phase == 'ip' else {'domain_suffix': ['ads.example']}]}
        path.write_text(json.dumps(doc))
PY

reset_db() {
    cat >"$DB_FILE" <<'JSON'
{"singbox":{"socks":{"port":44100,"username":"test","password":"test","auth_mode":"password"},"snell-v5":{"port":44105,"psk":"testSnellV5Key123","version":5},"snell-v6-singbox":{"port":44106,"psk":"testSnellV6Key123","version":6}},"snell":{},"routing":{"warp_mode":"disabled"},"routing_rules":[]}
JSON
}

test_global_phases() {
    reset_db
    rewrite_db '.routing_rules = [
        {id:"catchall",name:"first manually",type:"all",outbound:"balancer:pool",routing_priority:{singbox:0}},
        {id:"mixed",name:"unchanged",type:"custom",outbound:"chain:node",ip_version:"ipv4_only",routing_priority:{singbox:1},domains:"rule-set:skk-ip-china_ip,example.test,192.0.2.0/24,rule-set:skk-non-ip-telegram,rule-set:skk-domainset-reject"},
        {id:"youtube",type:"youtube",outbound:"balancer:pool",domains:"geosite:youtube"},
        {id:"warp",type:"custom",outbound:"warp",ip_version:"ipv6_only",domains:"rule-set:skk-non-ip-ai,rule-set:skk-ip-ai"},
        {id:"direct",type:"custom",outbound:"direct",ip_version:"as_is",domains:"direct.example"}]'
    cp "$DB_FILE" "$TEST_TMP/db.before"
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    assert_json 'map(if .rule_set then (if (.rule_set[0]|startswith("skk-domainset-")) then 0 elif (.rule_set[0]|test("^(skk|yuu)-non-ip-")) then 1 else 2 end) elif .domain_suffix then 0 elif .ip_cidr then 2 else 3 end) | . == sort' "$TEST_TMP/rules.json"
    assert_json '.[-1] == {outbound:"balancer-pool"}' "$TEST_TMP/rules.json"
    assert_json '[.[] | select(.outbound == "chain-node-ipv4")] | length == 5 and all(.[]; .ip_version == 4)' "$TEST_TMP/rules.json"
    assert_json '[.[] | select(.outbound == "warp-ipv6")] | length == 2 and all(.[]; .ip_version == 6)' "$TEST_TMP/rules.json"
    assert_json 'any(.[]; .outbound == "direct-asis") and any(.[]; .rule_set == ["skk-ip-china_ip"])' "$TEST_TMP/rules.json"
    assert_json 'all(.[]; ((has("rule_set") and has("ip_cidr")) | not)) and all(.[] | .ip_cidr[]?; . != "0.0.0.0/0" and . != "::/0")' "$TEST_TMP/rules.json"
    cmp "$TEST_TMP/db.before" "$DB_FILE"
}

test_default_priority() {
    reset_db
    for preset in google stream youtube stream-jp singbox-ai; do
        db_add_routing_rule "$preset" direct '' as_is
    done
    db_add_routing_rule all direct '' as_is
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    assert_json '[.[] | .rule_set[0]? | select(. != null)] == ["skk-non-ip-ai","yuu-non-ip-youtube","skk-non-ip-stream_jp","skk-non-ip-stream","yuu-non-ip-google","skk-ip-ai","skk-ip-stream_jp","skk-ip-stream"]' "$TEST_TMP/rules.json"
    cp "$DB_FILE" "$TEST_TMP/db.before"
    if db_add_routing_rule netflix direct '' as_is >"$TEST_TMP/rejected.log" 2>&1; then fail 'unsupported preset persisted'; fi
    cmp "$TEST_TMP/db.before" "$DB_FILE"
}

test_menu_and_access() {
    _select_outbound() { printf 'direct\n'; }
    _regenerate_proxy_configs() { return 0; }
    _reload_ai_routing_core() { return 0; }
    _line() { :; }
    sleep() { :; }
    local key preset
    for key in 1 2 3 4 5 a b; do
        reset_db
        case "$key" in
            1) preset=singbox-ai ;; 2) preset=stream ;; 3) preset=stream-jp ;;
            4) preset=youtube ;; 5) preset=google ;; a) preset=all ;; b) preset=ads ;;
        esac
        _add_routing_rule <<<"$key"$'\n\n' >"$TEST_TMP/menu.log"
        assert_json ".routing_rules | length==1 and .[0].type==\"$preset\"" "$DB_FILE"
    done
    reset_db
    enable_access_restriction <<<'' >"$TEST_TMP/access.log"
    access_restriction_enabled || fail 'CN access rule not detected'
    assert_json '.routing_rules | length==1 and .[0].id=="restrict-cn" and .[0].outbound=="block" and (. [0].domains | contains("skk-ip-china_ip_ipv6"))' "$DB_FILE"
    cp "$DB_FILE" "$TEST_TMP/access.before"
    _regenerate_proxy_configs() { return 1; }
    if enable_access_restriction <<<'' >"$TEST_TMP/access.log" 2>&1; then fail 'failed CN activation succeeded'; fi
    cmp "$TEST_TMP/access.before" "$DB_FILE"
}

test_native_presets() {
    # Stored legacy domains are deliberately stale: preset expansion must resolve
    # the current mapping without rewriting user records or labels.
    reset_db
    rewrite_db '.routing_rules = (["singbox-ai","stream","stream-jp","ads"] | to_entries | map({id:(.key|tostring),name:.value,type:.value,outbound:"direct",ip_version:"as_is",domains:"geosite:obsolete",routing_priority:{singbox:(10-.key)}}))'
    cp "$DB_FILE" "$TEST_TMP/db.before"
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    assert_json '([.[].rule_set[]?] | sort) == (["skk-non-ip-stream","skk-ip-stream","skk-non-ip-stream_jp","skk-ip-stream_jp","skk-non-ip-ai","skk-ip-ai","skk-domainset-reject","skk-non-ip-reject","skk-ip-reject"] | sort)' "$TEST_TMP/rules.json"
    cmp "$TEST_TMP/db.before" "$DB_FILE"
}

test_legacy_tokens() {
    reset_db
    rewrite_db '.routing_rules = [{id:"legacy",type:"custom",outbound:"direct",domains:"geosite:cn,geoip:cn,geoip:telegram"}]'
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    assert_json '([.[].rule_set[]] | sort) == (["skk-non-ip-domestic","skk-ip-china_ip","skk-ip-china_ip_ipv6","skk-ip-telegram"] | sort)' "$TEST_TMP/rules.json"
    rewrite_db '.routing_rules[0].domains = "geosite:not-a-published-category"'
    if gen_singbox_routing_rules >"$TEST_TMP/rejected.json" 2>"$TEST_TMP/rejected.log"; then fail 'unknown legacy geosite accepted'; fi
    rewrite_db '.routing_rules[0].domains = "geoip:not-a-published-category"'
    if gen_singbox_routing_rules >"$TEST_TMP/rejected.json" 2>"$TEST_TMP/rejected.log"; then fail 'unknown legacy geoip accepted'; fi
}

test_native_downloads() {
    local tag source
    : >"$SUKKA_TEST_DOWNLOADS"
    for tag in skk-non-ip-stream skk-ip-stream skk-non-ip-stream_jp skk-ip-stream_jp skk-ip-china_ip; do
        _build_singbox_ruleset "$tag"
        source=$(_singbox_sukka_tag_source "$tag")
        jq -S . "$SUKKA_TEST_FIXTURES/$source.json" >"$TEST_TMP/expected-source"
        jq -S . "$(_singbox_ruleset_source_path "$tag")" >"$TEST_TMP/actual-source"
        cmp "$TEST_TMP/expected-source" "$TEST_TMP/actual-source"
    done
    printf '%s\n' https://ruleset.skk.moe/sing-box/non_ip/stream.json https://ruleset.skk.moe/sing-box/ip/stream.json https://ruleset.skk.moe/sing-box/non_ip/stream_jp.json https://ruleset.skk.moe/sing-box/ip/stream_jp.json https://ruleset.skk.moe/sing-box/ip/china_ip.json >"$TEST_TMP/expected-downloads"
    cmp "$TEST_TMP/expected-downloads" "$SUKKA_TEST_DOWNLOADS"
}

test_yuu_legacy() {
    reset_db
    rewrite_db '.routing_rules = [{id:"youtube",type:"custom",outbound:"direct",ip_version:"as_is",domains:"geosite:youtube"},{id:"google",type:"custom",outbound:"chain:node",ip_version:"ipv6_only",domains:"geosite:google"}]'
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    # The official Yuu site sources contain domains only; no inferred IP set.
    assert_json 'length == 2 and ([.[].rule_set[]] | sort) == ["yuu-non-ip-google","yuu-non-ip-youtube"] and all(.[]; (has("ip_cidr")|not))' "$TEST_TMP/rules.json"
    assert_json 'any(.[]; .outbound == "chain-node-ipv6" and .ip_version == 6) and any(.[]; .outbound == "direct-asis")' "$TEST_TMP/rules.json"
    : >"$SUKKA_TEST_DOWNLOADS"
    _ensure_singbox_rulesets_from_routing_rules "$(cat "$TEST_TMP/rules.json")"
    [[ -s "$SUKKA_TEST_DOWNLOADS" ]] || fail 'Yuu source was not downloaded'
    printf '%s\n' https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_site/google.json https://raw.githubusercontent.com/Yuu518/sing-box-rules/rule_set/rule_set_site/youtube.json >"$TEST_TMP/expected-downloads"
    cmp "$TEST_TMP/expected-downloads" "$SUKKA_TEST_DOWNLOADS"
    [[ "$(wc -l <"$SUKKA_TEST_DOWNLOADS")" == 2 ]] || fail 'unexpected number of Yuu source downloads'
    _build_singbox_ruleset_defs "$(cat "$TEST_TMP/rules.json")" >"$TEST_TMP/defs.json"
    assert_json 'all(.[]; .type == "local" and .format == "binary" and (has("url")|not))' "$TEST_TMP/defs.json"
    cp "$TEST_TMP/rules.json" "$TEST_TMP/legacy-yuu.json"
    rewrite_db '.routing_rules[0].type = "youtube" | .routing_rules[1].type = "google"'
    gen_singbox_routing_rules >"$TEST_TMP/rules.json"
    cmp "$TEST_TMP/legacy-yuu.json" "$TEST_TMP/rules.json"
}

test_removed_presets() {
    reset_db
    generate_singbox_config >"$TEST_TMP/generate.log"
    cp "$CFG/singbox.json" "$TEST_TMP/config.before"
    local preset
    for preset in netflix openai disney singbox-instagram; do
        rewrite_db ".routing_rules = [{id:\"old-id\",name:\"keep\",type:\"$preset\",outbound:\"direct\",domains:\"geosite:netflix\",routing_priority:{singbox:1}}]"
        cp "$DB_FILE" "$TEST_TMP/db.before"
        if generate_singbox_config >"$TEST_TMP/rejected.log" 2>&1; then fail "removed preset accepted: $preset"; fi
        [[ -s "$TEST_TMP/rejected.log" ]] || fail "missing diagnostic: $preset"
        cmp "$TEST_TMP/config.before" "$CFG/singbox.json"
        cmp "$TEST_TMP/db.before" "$DB_FILE"
    done
}

test_config_and_rollback() {
    reset_db
    rewrite_db '.routing_rules = (["singbox-ai","stream","stream-jp","youtube","google","ads"] | to_entries | map({id:("keep-id-"+(.key|tostring)),name:("keep-name-"+.value),type:.value,outbound:(if .value == "ads" then "block" else "direct" end),ip_version:"as_is",routing_priority:{singbox:(10-.key)}}))'
    cp "$DB_FILE" "$TEST_TMP/db.before"
    generate_singbox_config >"$TEST_TMP/generate.log"
    cmp "$TEST_TMP/db.before" "$DB_FILE"
    assert_json '.route.rule_set | length == 11 and all(.[]; .type == "local" and .format == "binary" and (.path|endswith(".srs")) and (has("url")|not))'
    "$SINGBOX_CONFIG_BINARY" check -c "$CFG/singbox.json"
    cp "$CFG/singbox.json" "$TEST_TMP/config.before"
    local source binary mode
    source=$(_singbox_ruleset_source_path skk-non-ip-ai)
    binary=$(_singbox_ruleset_path skk-non-ip-ai)
    cp "$source" "$TEST_TMP/source.before"
    cp "$binary" "$TEST_TMP/binary.before"
    for mode in invalid failed compiler; do
        export SUKKA_TEST_DOWNLOAD_MODE=valid SUKKA_TEST_COMPILE_FAIL=false
        case "$mode" in compiler) export SUKKA_TEST_COMPILE_FAIL=true ;; *) export SUKKA_TEST_DOWNLOAD_MODE="$mode" ;; esac
        # A refresh may successfully reuse the validated old cache.
        if ! _build_singbox_ruleset skk-non-ip-ai >"$TEST_TMP/refresh.log" 2>&1; then
            cat "$TEST_TMP/refresh.log" >&2
            fail "valid cache was not reused after $mode failure"
        fi
        cmp "$TEST_TMP/source.before" "$source"
        cmp "$TEST_TMP/binary.before" "$binary"
        cmp "$TEST_TMP/config.before" "$CFG/singbox.json"
        # The same failure without a cache must reject generation atomically.
        rm -f "$source" "$binary"
        if generate_singbox_config >"$TEST_TMP/rejected.log" 2>&1; then fail "uncached $mode failure accepted"; fi
        cmp "$TEST_TMP/config.before" "$CFG/singbox.json"
        cmp "$TEST_TMP/db.before" "$DB_FILE"
        cp "$TEST_TMP/source.before" "$source"
        cp "$TEST_TMP/binary.before" "$binary"
    done
    [[ -z "$(find "$CFG/ruleset" "$CFG/ruleset-src" -type f -name '.*' -print)" ]] || fail 'temporary ruleset files leaked'
}

failures=0
for test_case in test_global_phases test_default_priority test_menu_and_access test_native_presets test_legacy_tokens test_native_downloads test_yuu_legacy test_removed_presets test_config_and_rollback; do
    set +e
    (set -e; "$test_case")
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then printf 'ok - %s\n' "$test_case"; else printf 'not ok - %s (exit %s)\n' "$test_case" "$status" >&2; failures=$((failures+1)); fi
done
if [[ -n "$SUKKA_TEST_BINARY" ]]; then printf 'official compile/check: %s\n' "$SUKKA_TEST_BINARY"; else printf 'SKIP official compile/check: set SING_TEST_SINGBOX_BIN to an official binary\n'; fi
[[ "$failures" == 0 ]]
