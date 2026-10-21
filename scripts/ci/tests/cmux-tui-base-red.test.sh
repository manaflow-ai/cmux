#!/usr/bin/env bash
# scripts/ci/cmux-tui-rust-check.sh load_base_red: an entry past its expiry
# warns and is still skipped, so a calendar date cannot fail the base-red step
# on every PR (2026-10-20: cx-2ueez and cx-gz5dx expired and every fleet
# `cmux-ci run` step went red). A malformed entry still fails.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT=${CMUX_RUST_CHECK_SCRIPT:-$ROOT/scripts/ci/cmux-tui-rust-check.sh}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The function alone: the script runs its steps at top level.
sed -n '/^load_base_red() {$/,/^}$/p' "$SCRIPT" > "$TMP/fn.sh"
grep -q '^load_base_red() {$' "$TMP/fn.sh" || { echo "FAIL: load_base_red not found in $SCRIPT" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; echo "$out" >&2; exit 1; }
run() { # TSV: loads it, sets rc, out and skipped
  printf '%s\n' "$1" > "$TMP/base-red.tsv"
  set +e
  out=$(bash -c '
    set -u
    base_red_file="$1"; skip_args=(); skip_notes=()
    source "$2"
    load_base_red; rc=$?
    echo "SKIPS:${skip_args[*]-}"
    exit "$rc"' _ "$TMP/base-red.tsv" "$TMP/fn.sh" 2>&1)
  rc=$?
  set -e
  skipped=$(sed -n 's/^SKIPS://p' <<<"$out")
}
tab=$'\t'
expired="closed_delete::an_expired_base_red_test${tab}cx-test1${tab}2000-01-01${tab}any${tab}still red"
current="closed_delete::a_current_base_red_test${tab}cx-test2${tab}2999-12-31${tab}any${tab}still red"

run "$expired"
[[ $rc -eq 0 ]] || fail "an expired entry failed the step (rc=$rc)"
grep -q 'gate-notice: base-red WARNING: closed_delete::an_expired_base_red_test (bead cx-test1) expired 2000-01-01' <<<"$out" \
  || fail "an expired entry printed no warning naming its bead"
[[ "$skipped" == "--skip closed_delete::an_expired_base_red_test" ]] || fail "an expired entry is not skipped: $skipped"

run "$current"
[[ $rc -eq 0 ]] || fail "a current entry failed the step (rc=$rc)"
[[ "$skipped" == "--skip closed_delete::a_current_base_red_test" ]] || fail "a current entry is not skipped: $skipped"
! grep -q WARNING <<<"$out" || fail "a current entry warned"

run "closed_delete::a_base_red_test_without_date${tab}cx-test3${tab}soon${tab}any${tab}x"
[[ $rc -ne 0 ]] || fail "an entry without a date passed"
run "closed_delete::a_base_red_test_with_a_bad_bead${tab}NOT_A_BEAD${tab}2999-12-31${tab}any${tab}x"
[[ $rc -ne 0 ]] || fail "an entry with a bad bead id passed"
echo "PASS: cmux-tui base-red list"
