#!/usr/bin/env bash
# Official Xray downloads and upgrade transactions, with local HTTP/service fixtures.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_err() { printf '%s\n' "$*" >>"$TEST_TMP/errors"; }
_info() { :; }
export TMPDIR="$TEST_TMP/downloads"
export SING_TEST_XRAY_CALLS="$TEST_TMP/config-checks"
export SING_TEST_XRAY_CONFIG_FAILURE="$TEST_TMP/reject-config"
export SING_TEST_XRAY_VERSION_FAILURE="$TEST_TMP/reject-version"
mkdir -p "$TMPDIR" "$CFG/bin"
printf '26.2.1\n' >"$TEST_TMP/stable"
printf '26.3.0-beta.1\n' >"$TEST_TMP/prerelease"
MOCK_ARCH=x86_64
CORRUPT_DOWNLOAD=false
NETWORK_FAILURE=false
DIGEST_MODE=present
DGST_FORMAT=sha2-bare
DGST_METADATA=valid
DGST_FAILURE=false
SERVICE_RUNNING=false
SERVICE_ENABLED=false
FAIL_RESTART=false
FAIL_START=false
FAIL_STOP=false
WAIT_FAILURES=0

uname() { [[ "$*" == -m ]] || forbidden uname "$@"; printf '%s\n' "$MOCK_ARCH"; }
get_xray_protocols() {
    if [[ -f "$TEST_TMP/protocols" ]]; then printf 'vless\n'; fi
    # filter_installed can end with a failed match for another protocol.
    return 1
}
generate_xray_config() {
    local version
    [[ -n "${XRAY_CONFIG_BINARY:-}" && "$XRAY_CONFIG_BINARY" != "$CFG/bin/xray" ]] || fail 'config checked with live core'
    version=$("$XRAY_CONFIG_BINARY" version | awk 'NR == 1 {print $2}') || return 1
    jq -n --arg version "$version" '{validated_by:$version,inbounds:[{protocol:"vless"}]}' >"$1" || return 1
    "$XRAY_CONFIG_BINARY" run -test -config "$1" >/dev/null
}
write_xray_binary() {
    printf '#!/usr/bin/env bash\nfixture_version=%q\n' "$2" >"$1"
    cat >>"$1" <<'SH'
case "$1" in
    version)
        [[ ! -f "$SING_TEST_XRAY_VERSION_FAILURE" ]] || exit 1
        printf 'Xray %s (Xray, Penetrates Everything.) fixture\n' "$fixture_version" ;;
    run)
        [[ "$2" == -test && "$3" == -config ]] || exit 2
        printf '%s|%s\n' "$fixture_version" "$4" >>"$SING_TEST_XRAY_CALLS"
        [[ ! -f "$SING_TEST_XRAY_CONFIG_FAILURE" ]] && jq -e '.validated_by and (.inbounds | length > 0)' "$4" >/dev/null ;;
    *) exit 2 ;;
esac
SH
    chmod 755 "$1"
}
make_package() {
    write_xray_binary "$TEST_TMP/package-xray" "$1"
    python3 - "$TEST_TMP/package-xray" "$TEST_TMP/official.zip" "${2:-valid}" <<'PY'
import pathlib, sys, zipfile
source, output, kind = sys.argv[1:]
if kind == 'invalid':
    pathlib.Path(output).write_text('not a ZIP archive')
else:
    with zipfile.ZipFile(output, 'w') as archive:
        archive.write(source, 'xray')
        if kind == 'unsafe':
            archive.writestr('../escaped', 'unsafe archive')
PY
}
curl() {
    local output='' url='' asset digest release_url
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            -H|--connect-timeout|--max-time|--retry) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$TEST_TMP/requests"
    [[ "$NETWORK_FAILURE" != true ]] || return 22
    case "$url" in
        https://api.github.com/repos/XTLS/Xray-core/releases/latest)
            jq -n --arg version "$(cat "$TEST_TMP/stable")" '{tag_name:("v"+$version)}' ;;
        "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$GITHUB_API_PER_PAGE")
            jq -n --arg stable "$(cat "$TEST_TMP/stable")" --arg test "$(cat "$TEST_TMP/prerelease")" '
                [{tag_name:"v99.0.0",draft:true,prerelease:true},
                 {tag_name:("v"+$test),draft:false,prerelease:true},
                 {tag_name:("v"+$stable),draft:false,prerelease:false}]' ;;
        https://api.github.com/repos/XTLS/Xray-core/releases/tags/v*)
            digest=$(_sha256_file "$TEST_TMP/official.zip")
            release_url="https://github.com/XTLS/Xray-core/releases/download/${url##*/}"
            case "$DIGEST_MODE" in
                missing) digest='' ;;
                wrong) digest=$(printf '%064d' 0) ;;
            esac
            jq -n --arg digest "$digest" --arg base "$release_url" --arg metadata "$DGST_METADATA" '
                ["64","arm64-v8a","arm32-v7a"] | map("Xray-linux-"+.+".zip") as $names |
                {assets:([{name:"unrelated.zip.dgst",browser_download_url:"https://example.invalid/unrelated.zip.dgst"}] +
                    [$names[] | {name:.,digest:(if $digest == "" then null else "sha256:"+$digest end),
                        browser_download_url:($base+"/"+.)}] +
                    [$names[] | {name:(.+".dgst"),browser_download_url:($base+"/"+.+".dgst"+
                        (if $metadata == "wrong-url" then "?untrusted" else "" end))}])}' ;;
        https://github.com/XTLS/Xray-core/releases/download/v*/Xray-linux-*.zip.dgst)
            [[ -n "$output" ]] || fail 'checksum download missing output path'
            [[ "$DGST_FAILURE" != true ]] || return 22
            asset="${url##*/}"; asset="${asset%.dgst}"
            digest=$(_sha256_file "$TEST_TMP/official.zip")
            case "$DGST_FORMAT" in
                sha2-bare) printf 'MD5= 0123456789abcdef0123456789abcdef\nSHA2-256= %s\nSHA2-512= ignored\n' "$digest" ;;
                sha2-named) printf 'SHA2-256(%s) = %s\r\n' "$asset" "${digest^^}" ;;
                sha256-bare) printf 'SHA256= %s' "$digest" ;;
                sha256-named) printf 'SHA256(%s)= %s\n' "$asset" "$digest" ;;
                wrong-hash) printf 'SHA256= %064d\n' 0 ;;
                short-hash) printf 'SHA256= %s\n' "${digest:0:63}" ;;
                missing-sha256) printf 'SHA1= %s\n' "$digest" ;;
                wrong-archive) printf 'SHA2-256(Xray-linux-other.zip)= %s\n' "$digest" ;;
                conflicting) printf 'SHA256= %s\nSHA2-256= %064d\n' "$digest" 0 ;;
                malformed) printf 'SHA256= %s trailing-data\n' "$digest" ;;
                *) fail "unknown checksum fixture: $DGST_FORMAT" ;;
            esac >"$output" ;;
        https://github.com/XTLS/Xray-core/releases/download/v*/Xray-linux-*.zip)
            [[ -n "$output" ]] || fail 'download missing output path'
            printf '%s\n' "$output" >"$TEST_TMP/download-path"
            if [[ "$CORRUPT_DOWNLOAD" == true ]]; then printf 'corrupt bytes\n' >"$output"
            else cp "$TEST_TMP/official.zip" "$output"; fi ;;
        *) fail "unexpected HTTP request: $url" ;;
    esac
}
svc() {
    [[ "$2" == sing-xray ]] || forbidden svc "$@"
    printf '%s\n' "$1" >>"$TEST_TMP/service-calls"
    case "$1" in
        status) [[ "$SERVICE_RUNNING" == true ]] ;;
        restart)
            cp "$CFG/bin/xray" "$TEST_TMP/attempted-binary"
            cp "$CFG/xray.json" "$TEST_TMP/attempted-config"
            SERVICE_RUNNING=false
            [[ "$FAIL_RESTART" != true ]] || return 1
            SERVICE_RUNNING=true ;;
        start)
            [[ "$FAIL_START" != true ]] || return 1
            SERVICE_RUNNING=true ;;
        stop)
            [[ "$FAIL_STOP" != true ]] || return 1
            SERVICE_RUNNING=false ;;
        *) forbidden svc "$@" ;;
    esac
}
_wait_for_owned_service() {
    [[ "$*" == sing-xray ]] || forbidden _wait_for_owned_service "$@"
    printf 'wait\n' >>"$TEST_TMP/service-calls"
    if ((WAIT_FAILURES > 0)); then WAIT_FAILURES=$((WAIT_FAILURES - 1)); return 1; fi
    [[ "$SERVICE_RUNNING" == true ]]
}
seed_installed() {
    rm -f "$CFG/paused" "$TEST_TMP/reject-config" "$TEST_TMP/reject-version"
    touch "$TEST_TMP/protocols"
    write_xray_binary "$CFG/bin/xray" 26.1.0
    chmod 750 "$CFG/bin/xray"
    printf '{"original":"configuration"}\n' >"$CFG/xray.json"
    chmod 600 "$CFG/xray.json"
    cp -p "$CFG/bin/xray" "$TEST_TMP/original-binary"
    cp -p "$CFG/xray.json" "$TEST_TMP/original-config"
    : >"$TEST_TMP/service-calls"
    : >"$TEST_TMP/config-checks"
    SERVICE_RUNNING=false
    SERVICE_ENABLED=false
    FAIL_RESTART=false
    FAIL_START=false
    FAIL_STOP=false
    WAIT_FAILURES=0
    CORRUPT_DOWNLOAD=false
    DIGEST_MODE=present
    DGST_FORMAT=sha2-bare
    DGST_METADATA=valid
    DGST_FAILURE=false
    MOCK_ARCH=x86_64
    make_package 26.2.1
}
assert_original() {
    cmp "$TEST_TMP/original-binary" "$CFG/bin/xray" || fail 'original binary changed'
    cmp "$TEST_TMP/original-config" "$CFG/xray.json" || fail 'original configuration changed'
    [[ "$(stat -c %a "$CFG/bin/xray")" == 750 && "$(stat -c %a "$CFG/xray.json")" == 600 ]] || fail 'rollback changed file modes'
}
assert_clean() {
    [[ -z "$(find "$CFG" -name '.xray-*' -o -name '*.new.*')" ]] || fail 'transaction files retained'
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]] || fail 'download staging retained'
    [[ -z "${XRAY_CONFIG_BINARY+x}" ]] || fail 'candidate binary override leaked'
}
assert_no_activation() {
    if grep -Eq '^(start|restart|stop|wait|enable|disable)$' "$TEST_TMP/service-calls"; then fail 'stopped/paused service changed'; fi
}

# Both channels use fresh official release metadata, including after a failed query.
[[ "$(_core_binary_path xray)" == "$CFG/bin/xray" && "$(_get_core_version xray)" == 未安装 ]]
[[ "$(_core_target_version xray stable)" == 26.2.1 ]]
[[ "$(_core_target_version xray prerelease)" == 26.3.0-beta.1 ]]
printf '26.2.2\n' >"$TEST_TMP/stable"
printf '26.3.0-beta.2\n' >"$TEST_TMP/prerelease"
[[ "$(_core_target_version xray stable)" == 26.2.2 && "$(_core_target_version xray prerelease)" == 26.3.0-beta.2 ]]
[[ "$(wc -l <"$TEST_TMP/requests")" == 4 ]] || fail 'version query did not contact remote on every call'
printf 'stale cached version\n' >"$CFG/.version-cache"
NETWORK_FAILURE=true
if _core_target_version xray stable; then fail 'failed query accepted stale stable version'; fi
if _core_target_version xray prerelease; then fail 'failed query accepted stale prerelease version'; fi
NETWORK_FAILURE=false
printf 'invalid/version\n' >"$TEST_TMP/stable"
if _core_target_version xray stable; then fail 'malformed remote version accepted'; fi
if _core_target_version xray unknown; then fail 'unknown channel accepted'; fi
printf '26.2.1\n' >"$TEST_TMP/stable"
printf '26.3.0-beta.1\n' >"$TEST_TMP/prerelease"
printf 'ok - Xray stable/prerelease queries use fresh official metadata and reject failed or invalid responses\n'

# Install the real fixture ZIP with each supported official asset name.
for mapping in 'x86_64:64' 'aarch64:arm64-v8a' 'armv7l:arm32-v7a'; do
    MOCK_ARCH="${mapping%%:*}"
    rm -f "$CFG/bin/xray" "$CFG/xray.json" "$TEST_TMP/protocols"
    make_package 26.2.1
    install_xray
    [[ "$(_get_core_version xray)" == 26.2.1 && "$(stat -c %a "$CFG/bin/xray")" == 755 && ! -e "$CFG/xray.json" ]]
    grep -Fq "/v26.2.1/Xray-linux-${mapping#*:}.zip" "$TEST_TMP/requests" || fail 'incorrect architecture asset'
    assert_clean
done
request_count=$(wc -l <"$TEST_TMP/requests")
install_xray prerelease
[[ "$(wc -l <"$TEST_TMP/requests")" == "$request_count" && "$(_get_core_version xray)" == 26.2.1 ]] || fail 'non-force install replaced existing core'
make_package 26.3.0-beta.1
install_xray prerelease true
[[ "$(_get_core_version xray)" == 26.3.0-beta.1 ]] || fail 'forced prerelease not installed'
make_package 26.2.9
install_xray stable true v26.2.9
[[ "$(_get_core_version xray)" == 26.2.9 ]] || fail 'explicit version not installed'
MOCK_ARCH=unsupported
if install_xray stable true 26.2.1; then fail 'unsupported architecture accepted'; fi
MOCK_ARCH=x86_64
printf 'ok - official ZIP installs map all architectures and honor channel, force and explicit version\n'

for rejection in corrupt invalid unsafe wrong-version bad-version-command invalid-config; do
    seed_installed
    case "$rejection" in
        corrupt) CORRUPT_DOWNLOAD=true ;;
        invalid|unsafe) make_package 26.2.1 "$rejection" ;;
        wrong-version) make_package 26.2.8 ;;
        bad-version-command) touch "$TEST_TMP/reject-version" ;;
        invalid-config) touch "$TEST_TMP/reject-config" ;;
    esac
    if install_xray stable true; then fail "accepted $rejection candidate"; fi
    assert_original
    assert_no_activation
    assert_clean
    [[ ! -e "$TMPDIR/escaped" ]] || fail 'archive escaped staging directory'
    if [[ "$rejection" == invalid-config ]]; then
        grep -q '^26.2.1|' "$TEST_TMP/config-checks" || fail 'candidate did not validate generated config'
    fi
done
printf 'ok - corrupt/unsafe archives, wrong versions and rejected candidate configs leave original files intact\n'

for format in sha2-bare sha2-named sha256-bare sha256-named; do
    seed_installed
    DIGEST_MODE=missing
    DGST_FORMAT="$format"
    install_xray stable true
    [[ "$(_get_core_version xray)" == 26.2.1 ]] || fail "$format checksum not accepted"
    [[ "$(tail -n 1 "$TEST_TMP/requests")" == https://github.com/XTLS/Xray-core/releases/download/v26.2.1/Xray-linux-64.zip.dgst ]] || fail 'checksum URL did not match exact archive'
    assert_json '.validated_by == "26.2.1"' "$CFG/xray.json"
    assert_no_activation
    assert_clean
done
printf 'ok - missing GitHub digests fall back to the exact official .dgst asset in all upstream SHA256 formats\n'

for rejection in wrong-hash short-hash missing-sha256 wrong-archive conflicting malformed checksum-download wrong-url corrupt advertised-mismatch; do
    seed_installed
    DIGEST_MODE=missing
    case "$rejection" in
        checksum-download) DGST_FAILURE=true ;;
        wrong-url) DGST_METADATA=wrong-url ;;
        corrupt) CORRUPT_DOWNLOAD=true ;;
        advertised-mismatch) DIGEST_MODE=wrong ;;
        *) DGST_FORMAT="$rejection" ;;
    esac
    dgst_requests=$(grep -c '\.zip\.dgst$' "$TEST_TMP/requests" || :)
    if ALLOW_UNVERIFIED_DOWNLOADS=1 install_xray stable true; then fail "accepted $rejection checksum fallback"; fi
    if [[ "$rejection" == advertised-mismatch || "$rejection" == wrong-url ]]; then
        [[ "$(grep -c '\.zip\.dgst$' "$TEST_TMP/requests" || :)" == "$dgst_requests" ]] || fail 'fallback bypassed mismatched advertised digest or URL'
    fi
    assert_original
    assert_no_activation
    assert_clean
done
printf 'ok - invalid/missing/mismatched .dgst checksums reject installation without bypassing advertised digests\n'

# A failure committing the config must also undo the already replaced binary.
seed_installed
(
    mv() {
        if [[ "$1" == -f && "$2" == "$CFG"/.xray-upgrade.* ]]; then return 1; fi
        command mv "$@"
    }
    if install_xray stable true; then fail 'failed config replacement accepted'; fi
    assert_original
    assert_clean
)
printf 'ok - config commit failure atomically restores the previous binary and configuration\n'

for state in running stopped paused; do
    for enabled in true false; do
        seed_installed
        SERVICE_ENABLED="$enabled"
        case "$state" in
            running) SERVICE_RUNNING=true ;;
            paused) printf 'paused sentinel\n' >"$CFG/paused" ;;
        esac
        update_xray_core stable
        [[ "$(_get_core_version xray)" == 26.2.1 && "$SERVICE_ENABLED" == "$enabled" ]] || fail 'update or enablement state changed'
        assert_json '.validated_by == "26.2.1"' "$CFG/xray.json"
        [[ "$(stat -c %a "$CFG/xray.json")" == 600 ]] || fail 'candidate config permissions'
        if [[ "$state" == running ]]; then
            [[ "$SERVICE_RUNNING" == true ]] || fail 'running service not restarted'
            grep -qx restart "$TEST_TMP/service-calls"
            grep -qx wait "$TEST_TMP/service-calls"
        else
            [[ "$SERVICE_RUNNING" == false ]] || fail 'stopped service activated'
            assert_no_activation
        fi
        [[ "$state" != paused ]] || grep -qx 'paused sentinel' "$CFG/paused"
        assert_clean
    done
done
printf 'ok - successful updates validate configs, await running services and preserve stopped/paused and enabled states\n'

for failure in restart readiness; do
    seed_installed
    SERVICE_RUNNING=true
    SERVICE_ENABLED=true
    make_package 26.3.0-beta.1
    if [[ "$failure" == restart ]]; then FAIL_RESTART=true; else WAIT_FAILURES=1; fi
    if _update_xray_core_to_version prerelease 26.3.0-beta.1; then fail "failed $failure accepted"; fi
    assert_original
    assert_json '.validated_by == "26.3.0-beta.1"' "$TEST_TMP/attempted-config"
    [[ "$SERVICE_RUNNING" == true && "$SERVICE_ENABLED" == true ]] || fail 'rollback did not restore running service'
    grep -qx restart "$TEST_TMP/service-calls"
    grep -qx stop "$TEST_TMP/service-calls"
    grep -qx start "$TEST_TMP/service-calls"
    grep -qx wait "$TEST_TMP/service-calls"
    assert_clean
done
printf 'ok - failed restart/readiness rolls back binary, config and modes, then waits for the original service\n'

seed_installed
SERVICE_RUNNING=true
touch "$TEST_TMP/reject-config"
if update_xray_core stable; then fail 'invalid upgrade config accepted'; fi
assert_original
assert_no_activation
[[ "$SERVICE_RUNNING" == true ]] || fail 'validation failure interrupted running service'
assert_clean

partial_installer() {
    write_xray_binary "$CFG/bin/xray" "$3"
    printf '{"partial":true}\n' >"$CFG/xray.json"
    return 1
}
for state in stopped paused absent; do
    seed_installed
    [[ "$state" != paused ]] || touch "$CFG/paused"
    [[ "$state" != absent ]] || rm -f "$CFG/bin/xray" "$CFG/xray.json"
    if _update_xray_core_to_version stable 26.2.1 partial_installer; then fail 'partial installer failure accepted'; fi
    if [[ "$state" == absent ]]; then [[ ! -e "$CFG/bin/xray" && ! -e "$CFG/xray.json" ]]; else assert_original; fi
    [[ "$state" != paused ]] || [[ -f "$CFG/paused" ]]
    assert_no_activation
    assert_clean
done
printf 'ok - failed validation leaves running services untouched and partial installs roll back without activating stopped services\n'

for failure in stop start; do
    seed_installed
    SERVICE_RUNNING=true
    FAIL_RESTART=true
    if [[ "$failure" == stop ]]; then FAIL_STOP=true; else FAIL_START=true; fi
    if update_xray_core stable; then fail 'unrecoverable rollback accepted'; fi
    snapshots=("$CFG"/.xray-core.*)
    [[ ${#snapshots[@]} == 1 && -d "${snapshots[0]}" ]] || fail 'unrecoverable failure discarded snapshot'
    cmp "$TEST_TMP/original-binary" "${snapshots[0]}/binary"
    cmp "$TEST_TMP/original-config" "${snapshots[0]}/config"
    [[ "$(stat -c %a "${snapshots[0]}")" == 700 ]] || fail 'snapshot permissions'
    grep -Fq "${snapshots[0]}" "$TEST_TMP/errors" || fail 'retained snapshot not reported'
    [[ "$failure" != start ]] || assert_original
    rm -rf "${snapshots[0]}"
    assert_clean
done
printf 'ok - unrecoverable stop/start failures preserve and report private binary/config snapshots\n'

# Exercise the real version display and interactive menu dispatch for Xray.
seed_installed
_show_core_versions xray >"$TEST_TMP/display"
grep -q 'Xray 当前: 26.1.0  稳定: 26.2.1  测试: 26.3.0-beta.1' "$TEST_TMP/display"
make_package 26.3.0-beta.1
update_core_menu <<<'1
2
0' >"$TEST_TMP/menu" || :
[[ "$(_get_core_version xray)" == 26.3.0-beta.1 ]] || fail 'Xray menu did not dispatch prerelease update'
assert_no_activation
assert_clean
printf 'ok - Xray version display and update menu dispatch current official channels\n'
