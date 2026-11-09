#!/usr/bin/env bash
# Real query/download/verification helpers, with HTTP responses mocked locally.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
_warn() { :; }
_err() { :; }
[[ "$(_script_update_ref stable)" == main && "$(_script_update_ref dev)" == dev ]]
if _script_update_ref unknown; then fail 'unknown update branch accepted'; fi
printf '#!/bin/bash\nreadonly VERSION="99.1.0"\n' >"$TEST_TMP/remote-script"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$TEST_TMP/commit"
printf 'v1.14.4\n' >"$TEST_TMP/release"
printf 'stale cached version\n' >"$CFG/.version-cache"
git_blob=$(python3 - "$TEST_TMP/remote-script" <<'PY'
import hashlib, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest())
PY
)
curl() {
    local output='' url='' arg
    [[ ! -f "$TEST_TMP/network-failure" ]] || return 22
    while (($#)); do
        case "$1" in
            -o) output="$2"; shift 2 ;;
            -H|--connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >>"$TEST_TMP/requests"
    case "$url" in
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest") jq -n --arg v "$(cat "$TEST_TMP/release")" '{tag_name:$v}' ;;
        "https://api.github.com/repos/${SCRIPT_SOURCE_REPO}/commits/main"|"https://api.github.com/repos/${SCRIPT_SOURCE_REPO}/commits/dev")
            jq -n --arg sha "$(cat "$TEST_TMP/commit")" '{sha:$sha}' ;;
        "https://raw.githubusercontent.com/${SCRIPT_SOURCE_REPO}/$(cat "$TEST_TMP/commit")/${SCRIPT_SOURCE_PATH}")
            [[ -n "$output" ]] || fail 'script download missing output path'
            cp "$TEST_TMP/remote-script" "$output"
            printf '%s\n' "$output" >"$TEST_TMP/download-path" ;;
        "https://api.github.com/repos/${SCRIPT_SOURCE_REPO}/contents/${SCRIPT_SOURCE_PATH}?ref=$(cat "$TEST_TMP/commit")")
            jq -n --arg sha "${mock_blob:-$git_blob}" '{sha:$sha}' ;;
        *) fail "unexpected HTTP request: $url" ;;
    esac
}
[[ "$(_get_latest_version SagerNet/sing-box)" == 1.14.4 ]]
printf 'v1.14.5\n' >"$TEST_TMP/release"
[[ "$(_get_latest_version SagerNet/sing-box)" == 1.14.5 ]] || fail 'core version query cached'
[[ "$(wc -l <"$TEST_TMP/requests")" == 2 ]] || fail 'core query did not fetch on each call'
printf 'ok - core versions query fresh remote metadata on every call\n'

[[ "$(_get_latest_script_version_from_raw main)" == 99.1.0 ]]
printf '#!/bin/bash\nreadonly VERSION="99.2.0"\n' >"$TEST_TMP/remote-script"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$TEST_TMP/commit"
git_blob=$(python3 - "$TEST_TMP/remote-script" <<'PY'
import hashlib, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest())
PY
)
[[ "$(_get_latest_script_version_from_raw main)" == 99.2.0 ]] || fail 'script branch query cached'
[[ ! -e "$(cat "$TEST_TMP/download-path")" ]] || fail 'version lookup left downloaded script'
_get_latest_script_version_from_raw dev >/dev/null
grep -q '/commits/dev$' "$TEST_TMP/requests" || fail 'dev branch not resolved live'
if grep -Eq 'raw.githubusercontent.com/.*/(main|dev)/' "$TEST_TMP/requests"; then fail 'download used mutable raw branch'; fi
_check_script_update
[[ "$SCRIPT_REMOTE_VERSION" == 99.2.0 ]]
touch "$TEST_TMP/network-failure"
if _check_script_update; then fail 'failed remote query accepted cached script version'; fi
[[ -z "$SCRIPT_REMOTE_VERSION" ]] || fail 'failed query retained previous result'
rm "$TEST_TMP/network-failure"
printf 'ok - script branches resolve live commits and failed queries discard stale results\n'

mock_blob=cccccccccccccccccccccccccccccccccccccccc
if _fetch_script_tmp 5 10 dev >"$TEST_TMP/rejected" 2>&1; then fail 'mismatched GitHub blob accepted'; fi
[[ ! -e "$(cat "$TEST_TMP/download-path")" ]] || fail 'rejected script download was not removed'
printf 'ok - commit-pinned script downloads require a matching GitHub blob digest\n'
