#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=hosted-retention.sh
source "$ROOT/scripts/hosted-retention.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-hosted-retention-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

current_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
new_commit="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
active_commit="cccccccccccccccccccccccccccccccccccccccc"
old_commit="dddddddddddddddddddddddddddddddddddddddd"

fake_lsof="$tmp/lsof"
cat > "$fake_lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${CMUX_TEST_LSOF_MODE:-inactive}" == error ]]; then
  echo 'simulated lsof failure' >&2
  exit 1
fi

[[ "${CMUX_TEST_LSOF_MODE:-inactive}" == active ]] || exit 1
for argument in "$@"; do
  if [[ "$argument" == /*/cmux-tui ]]; then
    if [[ "${argument##*/}" == cmux-tui && "$argument" == *"/${CMUX_TEST_ACTIVE_COMMIT:-}"/* ]]; then
      printf 'n%s\n' "$argument"
    fi
  fi
done
exit 1
EOF
chmod 0755 "$fake_lsof"

fake_stat="$tmp/stat"
cat > "$fake_stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

format="${1:-}"
case "${CMUX_TEST_STAT_MODE:-gnu}:$format" in
  gnu:-c|bsd:-f)
    shift 2
    ;;
  gnu:-f|bsd:-c)
    # GNU stat's -f is filesystem status, not file modification time. Return
    # a successful non-numeric value to catch callers that accept that result.
    printf '/mounted\n'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac

candidate="${1##*/}"
awk -F '\t' -v candidate="$candidate" '$1 == candidate { print $2; found = 1 } END { exit(found ? 0 : 1) }' \
  "$CMUX_TEST_STAT_MAP"
EOF
chmod 0755 "$fake_stat"

make_root() {
  test_root="$tmp/root-$RANDOM"
  mkdir -p "$test_root"
}

make_artifact() {
  local commit="$1"
  mkdir -p "$test_root/$commit"
  printf '%s\n' "$commit" > "$test_root/$commit/cmux-tui"
}

write_stat_map() {
  : > "$tmp/stat-map"
  for entry in "$@"; do
    printf '%s\n' "$entry" >> "$tmp/stat-map"
  done
  export CMUX_TEST_STAT_MAP="$tmp/stat-map"
}

run_retention() {
  CMUX_TUI_HOSTED_RETENTION_COUNT="$test_count" \
  CMUX_TUI_HOSTED_RETENTION_DRY_RUN="$test_dry_run" \
  CMUX_TUI_HOSTED_RETENTION_CONFIRM="$test_confirm" \
  CMUX_TUI_HOSTED_RETENTION_LSOF="$fake_lsof" \
  CMUX_TUI_HOSTED_RETENTION_STAT="$fake_stat" \
  CMUX_TEST_LSOF_MODE="${test_lsof_mode:-inactive}" \
  CMUX_TEST_ACTIVE_COMMIT="${test_active_commit:-}" \
  CMUX_TEST_STAT_MODE="${test_stat_mode:-gnu}" \
  cmux_hosted_retention_run "$test_root" "$test_current_commit"
}

expect_success() {
  if ! run_retention >"$tmp/stdout" 2>"$tmp/stderr"; then
    echo "expected success" >&2
    cat "$tmp/stderr" >&2
    exit 1
  fi
}

expect_failure() {
  local expected_status="$1"
  local actual_status
  if run_retention >"$tmp/stdout" 2>"$tmp/stderr"; then
    echo "expected failure with status $expected_status" >&2
    exit 1
  else
    actual_status=$?
  fi
  if [[ "$actual_status" -ne "$expected_status" ]]; then
    echo "expected status $expected_status, got $actual_status" >&2
    cat "$tmp/stderr" >&2
    exit 1
  fi
}

assert_exists() {
  [[ -e "$test_root/$1" ]] || { echo "missing expected path: $1" >&2; exit 1; }
}

assert_missing() {
  [[ ! -e "$test_root/$1" ]] || { echo "unexpected path: $1" >&2; exit 1; }
}

make_baseline() {
  make_root
  make_artifact "$current_commit"
  make_artifact "$new_commit"
  make_artifact "$active_commit"
  make_artifact "$old_commit"
  write_stat_map \
    "$current_commit\t400" \
    "$new_commit\t300" \
    "$active_commit\t200" \
    "$old_commit\t100"
  test_current_commit="$current_commit"
  test_count=1
  test_dry_run=1
  test_confirm=0
  test_lsof_mode=inactive
  test_active_commit=""
  test_stat_mode=gnu
}

# A dry run creates the preview. A destructive run with the same plan removes
# only the inactive tail, while retaining the current and newest prior item.
make_baseline
expect_success
assert_exists .retention-preview
test_dry_run=0
test_confirm=1
expect_success
assert_exists "$current_commit"
assert_exists "$new_commit"
assert_missing "$active_commit"
assert_missing "$old_commit"

# The preview binds the retention policy. Changing the count cannot reuse it.
make_baseline
expect_success
test_dry_run=0
test_count=2
test_confirm=1
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# The preview binds the current commit. A different current artifact cannot
# reuse a prior preview even when the candidate directory set is unchanged.
make_baseline
expect_success
test_dry_run=0
test_current_commit="$new_commit"
test_confirm=1
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# Malformed, expired, and future timestamps are all rejected before cleanup.
make_baseline
expect_success
preview="$test_root/.retention-preview"
preview_hash="$(cut -f1 "$preview")"
printf '%s\tnot-a-timestamp\n' "$preview_hash" > "$preview"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$old_commit"

make_baseline
expect_success
preview="$test_root/.retention-preview"
preview_hash="$(cut -f1 "$preview")"
printf '%s\t%s\n' "$preview_hash" "$(( $(date +%s) + 1 ))" > "$preview"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$old_commit"

make_baseline
expect_success
preview="$test_root/.retention-preview"
preview_hash="$(cut -f1 "$preview")"
printf '%s\t%s\n' "$preview_hash" "$(( $(date +%s) - 601 ))" > "$preview"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$old_commit"

# An lsof error is not the same as an empty match. Cleanup must fail closed.
make_baseline
expect_success
test_dry_run=0
test_confirm=1
test_lsof_mode=error
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# An active binary is retained while a confirmed inactive binary is removed.
make_baseline
expect_success
test_dry_run=0
test_confirm=1
test_lsof_mode=active
test_active_commit="$active_commit"
expect_success
assert_exists "$active_commit"
assert_missing "$old_commit"

# Exercise both documented stat interfaces. The GNU form must be tried first
# on GNU systems, while the BSD form remains a valid fallback on macOS.
make_baseline
test_stat_mode=bsd
test_dry_run=1
expect_success
make_baseline
test_stat_mode=gnu
test_dry_run=1
expect_success

echo 'hosted retention behavior passed'
