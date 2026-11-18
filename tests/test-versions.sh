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

# Exercise the menu's actual update path, including staging, backup and system sync.
# Version-query helpers alone cannot catch obsolete calls in the interactive flow.
unset mock_blob
_current_script_path() { printf '%s\n' "$TEST_TMP/current.sh"; }
_system_script_path() { printf '%s\n' "$TEST_TMP/system.sh"; }
printf '#!/bin/bash\nreadonly VERSION="0.0.1"\n' >"$TEST_TMP/original.sh"
for channel in stable dev; do
    cp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh"
    cp "$TEST_TMP/original.sh" "$TEST_TMP/system.sh"
    chmod 755 "$TEST_TMP/current.sh" "$TEST_TMP/system.sh"
    rc=0
    LC_ALL=C _update_script_from_channel "$channel" <<<'n' >"$TEST_TMP/menu.log" 2>"$TEST_TMP/menu.err" || rc=$?
    [[ "$rc" == 2 ]] || fail "$channel cancellation status"
    cmp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh"
    cmp "$TEST_TMP/original.sh" "$TEST_TMP/system.sh"
    if grep -q 'command not found' "$TEST_TMP/menu.err"; then fail "$channel update called missing helper"; fi

    if ! LC_ALL=C _update_script_from_channel "$channel" <<<'y' >"$TEST_TMP/menu.log" 2>"$TEST_TMP/menu.err"; then
        fail "$channel menu update failed"
    fi
    if grep -q 'command not found' "$TEST_TMP/menu.err"; then fail "$channel update called missing helper"; fi
    cmp "$TEST_TMP/remote-script" "$TEST_TMP/current.sh"
    cmp "$TEST_TMP/remote-script" "$TEST_TMP/system.sh"
    cmp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh.bak"
    [[ "$(stat -c %a "$TEST_TMP/current.sh")" == 755 && "$(stat -c %a "$TEST_TMP/system.sh")" == 755 ]] || fail "$channel update permissions"
done
printf 'ok - stable/dev menu updates cancel cleanly or replace and sync verified scripts without missing helpers\n'

# A streamed or removed launcher can leave only the installed script available.
rm -f "$CFG/.version-cache" "$TEST_TMP/current.sh" "$TEST_TMP/current.sh.bak" "$TEST_TMP/system.sh"
rmdir "$CFG"
mkdir "$TEST_TMP/installed scripts"
installed="$TEST_TMP/installed scripts/sing-lite.sh"
ln -s "$installed" "$TEST_TMP/system.sh"
ln -s "$TEST_TMP/system.sh" "$TEST_TMP/vless"
cp "$TEST_TMP/original.sh" "$installed"
[[ "$(bash -c 'source "$1"; _current_script_path' "$TEST_TMP/vless" "$TEST_ROOT/vless-server.sh")" == "$installed" ]] ||
    fail 'could not resolve the vless symlink to its script'
if bash <(printf 'source "$1"\n_current_script_path\n') "$TEST_ROOT/vless-server.sh"; then
    fail 'streamed script was treated as a replaceable file'
fi
for channel in stable dev; do
    cp "$TEST_TMP/original.sh" "$installed"
    if ! _update_script_from_channel "$channel" <<<'y' >"$TEST_TMP/menu.log" 2>&1; then
        cat "$TEST_TMP/menu.log" >&2
        fail "$channel update could not use the installed script when the launcher was missing"
    fi
    [[ -L "$TEST_TMP/system.sh" && ! -e "$CFG" ]] || fail 'update changed the shortcut or created a config directory'
    cmp "$TEST_TMP/remote-script" "$installed"
    cmp "$TEST_TMP/original.sh" "$installed.bak"
done
printf 'ok - missing launchers fall back to the installed script without requiring a config directory\n'

# Simulate a launch directory where an atomic replacement cannot be staged.
cp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh"
cp "$TEST_TMP/original.sh" "$installed"
mktemp() {
    [[ "${1:-}" != "$TEST_TMP/current.sh.update.XXXXXX" ]] || return 1
    command mktemp "$@"
}
_update_script_from_channel stable <<<'y' >"$TEST_TMP/menu.log" 2>&1 ||
    fail 'update did not fall back when the launch directory could not stage a file'
cmp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh"
cmp "$TEST_TMP/remote-script" "$installed"
cmp "$TEST_TMP/original.sh" "$installed.bak"
[[ ! -e "$TEST_TMP/current.sh.bak" ]] || fail 'fallback created a backup in the launch directory'

printf '#!/bin/bash\nreadonly VERSION="99.3.0"\n' >"$installed"
rc=0
_update_script_from_channel stable <<<'y' >"$TEST_TMP/menu.log" 2>&1 || rc=$?
[[ "$rc" == 2 && "$(_extract_script_version "$installed")" == 99.3.0 ]] ||
    fail 'fallback downgraded a newer installed script'
unset -f mktemp
printf 'ok - launch directory staging failures update only the installed script without downgrading it\n'

# A failure at the final system rename must roll back the already replaced launcher.
cp "$TEST_TMP/original.sh" "$installed"
mv() {
    [[ "${@: -1}" != "$installed" ]] || return 1
    command mv "$@"
}
rc=0
_update_script_from_channel stable <<<'y' >"$TEST_TMP/menu.log" 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail 'failed system replacement reported success'
cmp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh"
cmp "$TEST_TMP/original.sh" "$installed"
cmp "$TEST_TMP/original.sh" "$TEST_TMP/current.sh.bak"
[[ -z "$(find "$TEST_TMP" -name '*.update.*' -print -quit)" ]] || fail 'update left staging files'
unset -f mv
printf 'ok - a failed system replacement rolls back the launcher and cleans up staging files\n'

# An inherited TMPDIR can refer to a directory removed before the menu opened.
download_path=$(TMPDIR="$TEST_TMP/missing downloads" _fetch_script_tmp 5 10 main) ||
    fail 'script download did not recover from a missing temporary directory'
cmp "$TEST_TMP/remote-script" "$download_path"
rm -f "$download_path"
printf 'ok - script downloads recover when TMPDIR is missing\n'
