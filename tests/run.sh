#!/usr/bin/env bash
# bash lite/tests/run.sh
# SING_TEST_SINGBOX_BIN=/tmp/official-sing-box bash lite/tests/run.sh
set -uo pipefail
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failed=0
for test_file in "$test_dir"/test-*.sh; do
    printf '\nRunning %s\n' "${test_file##*/}"
    if ! bash "$test_file"; then
        printf 'FAILED: %s\n' "${test_file##*/}" >&2
        failed=$((failed + 1))
    fi
done
if ((failed)); then
    printf '\n%d regression suite(s) failed\n' "$failed" >&2
    exit 1
fi
printf '\nAll lite regression suites passed\n'
