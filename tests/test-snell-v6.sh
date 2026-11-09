#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { :; }
init_db
db_add snell snell-v6 '{"port":47006,"psk":"testOfficialV6Key","version":6,"mode":"default"}'
db_add singbox snell-v6-singbox '[{"port":47016,"psk":"testSharedV6Key","version":6,"mode":"unshaped"},{"port":47017,"psk":"testOtherV6Key","version":6,"mode":"unsafe-raw"}]'
db_migrate_to_multiuser
assert_json 'all(.singbox["snell-v6-singbox"][]; has("users")|not)' "$DB_FILE"
generate_singbox_config
assert_json '(.inbounds|length)==2 and all(.inbounds[]; .type=="snell" and .version==6) and ([.inbounds[].tag]|unique|length)==2'
assert_json 'any(.inbounds[]; .listen_port==47016 and .mode=="unshaped") and any(.inbounds[]; .listen_port==47017 and .mode=="unsafe-raw")'
cp "$CFG/singbox.json" "$TEST_TMP/working"
for expression in '.version=5' '.mode="invalid"' '.psk="short"'; do
    cfg=$(jq ".[0] | $expression" <<<"$(db_get singbox snell-v6-singbox)")
    if _validate_singbox_snell_record "$cfg" snell-v6-singbox; then fail "accepted invalid v6: $expression"; fi
done
_wait_for_singbox_ready() { :; }
create_singbox_service() { :; }
RUNNING=true
ENABLED=true
FAIL_RESTART=false
svc() {
    [[ "$2" == sing-singbox ]] || forbidden svc "$@"
    case "$1" in
        status) [[ "$RUNNING" == true ]] ;;
        enabled) [[ "$ENABLED" == true ]] ;;
        enable) ENABLED=true ;;
        disable) ENABLED=false ;;
        stop) RUNNING=false ;;
        start) RUNNING=true ;;
        restart)
            if [[ "$FAIL_RESTART" == true ]]; then FAIL_RESTART=false; RUNNING=false; return 1; fi
            RUNNING=true ;;
        *) forbidden svc "$@" ;;
    esac
}
systemctl() { [[ "$*" == daemon-reload ]] || forbidden systemctl "$@"; }
regenerate_singbox_protocol_join_info snell-v6-singbox
cp "$DB_FILE" "$TEST_TMP/original-db"
cp "$CFG/snell-v6-singbox.join" "$TEST_TMP/original-join"
FAIL_RESTART=true
replacement='{"port":47018,"psk":"testReplacementV6","version":6,"mode":"default"}'
if _apply_singbox_vless_config "$replacement" replace 47016 snell-v6-singbox; then fail 'failed v6 restart committed'; fi
cmp "$TEST_TMP/original-db" "$DB_FILE"
cmp "$TEST_TMP/working" "$CFG/singbox.json"
cmp "$TEST_TMP/original-join" "$CFG/snell-v6-singbox.join"
[[ "$RUNNING" == true && "$ENABLED" == true ]]
_apply_singbox_vless_config '{}' remove 47016 snell-v6-singbox
assert_json '.inbounds|length==1 and .[0].listen_port==47017'
_apply_singbox_vless_config '{}' remove all snell-v6-singbox
assert_json '.singbox=={} and .snell["snell-v6"].port==47006' "$DB_FILE"
[[ "$RUNNING" == false && "$ENABLED" == false ]]
[[ ! -f "$CFG/snell-v6-singbox.join" ]]
printf 'ok - shared v6 modes, multiport, failed activation rollback and independent official service ownership\n'
