#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=hosted-retention.sh
source "$ROOT/scripts/hosted-retention.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-hosted-retention-test.XXXXXX")"
stop_race_process() {
  local race_pid
  if [[ -f "$tmp/race-pid" ]] && race_pid="$(<"$tmp/race-pid")" && [[ "$race_pid" =~ ^[0-9]+$ ]]; then
    kill "$race_pid" 2>/dev/null || true
  fi
  rm -f "$tmp/race-pid"
}
cleanup_test_processes() {
  stop_race_process
  rm -rf -- "$tmp"
}
trap cleanup_test_processes EXIT

current_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
new_commit="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
active_commit="cccccccccccccccccccccccccccccccccccccccc"
old_commit="dddddddddddddddddddddddddddddddddddddddd"
extra_commit="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

fake_lsof="$tmp/lsof"
cat > "$fake_lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${CMUX_TEST_LSOF_MODE:-inactive}" == error ]]; then
  echo 'simulated lsof failure' >&2
  exit 1
fi

if [[ "${CMUX_TEST_LSOF_MODE:-inactive}" == race ]]; then
  if [[ ! -e "${CMUX_TEST_LSOF_STATE:-}" ]]; then
    : > "$CMUX_TEST_LSOF_STATE"
    (
      exec 9<"$CMUX_TEST_RACE_BINARY"
      exec tail -f /dev/null
    ) &
    printf '%s\n' "$!" > "$CMUX_TEST_RACE_PID_FILE"
    exit 1
  fi
  race_match=0
  for argument in "$@"; do
    if [[ "$argument" == *"/${CMUX_TEST_RACE_COMMIT:-}/cmux-tui" ]]; then
      printf 'n%s\n' "$argument"
      race_match=1
    fi
  done
  if (( race_match )); then
    exit 0
  fi
  exit 1
fi

if [[ "${CMUX_TEST_LSOF_MODE:-inactive}" == partial ]]; then
  for argument in "$@"; do
    if [[ "$argument" == *"/${CMUX_TEST_ACTIVE_COMMIT:-}/cmux-tui" ]]; then
      printf 'n%s\n' "$argument"
      exit 1
    fi
  done
  exit 1
fi

[[ "${CMUX_TEST_LSOF_MODE:-inactive}" == active ]] || exit 1
active_match=0
for argument in "$@"; do
  if [[ "$argument" == /*/cmux-tui ]]; then
    if [[ "${argument##*/}" == cmux-tui && "$argument" == *"/${CMUX_TEST_ACTIVE_COMMIT:-}"/* ]]; then
      printf 'n%s\n' "$argument"
      active_match=1
    fi
  fi
done
(( active_match )) && exit 0
exit 1
EOF
chmod 0755 "$fake_lsof"

fake_find="$tmp/find"
cat > "$fake_find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CMUX_TEST_FIND_ARGS_FILE"
for argument in "$@"; do
  case "$argument" in
    -mindepth|-maxdepth)
      echo "simulated BSD find rejected GNU depth predicate: $argument" >&2
      exit 2
      ;;
  esac
done
exec /usr/bin/find "$@"
EOF
chmod 0755 "$fake_find"

fake_stat="$tmp/stat"
cat > "$fake_stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

format="${1:-}"
case "${CMUX_TEST_STAT_MODE:-gnu}:$format" in
  gnu:-c|bsd:-f)
    shift 2
    ;;
  gnu:-f)
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

fake_mv="$tmp/mv"
cat > "$fake_mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

/bin/mv "$@"
destination=""
for argument in "$@"; do
  destination="$argument"
done
if [[ "${CMUX_TEST_MV_MODE:-normal}" == publish-marker && "$destination" == *.reclaim ]]; then
  printf 'published-after-move\n' > "$destination/owner"
fi
EOF
chmod 0755 "$fake_mv"

make_root() {
  test_root="$(mktemp -d "$tmp/root.XXXXXX")"
}

make_artifact() {
  local commit="$1"
  mkdir -p "$test_root/$commit"
  printf '%s\n' "$commit" > "$test_root/$commit/cmux-tui"
}

write_stat_map() {
  : > "$tmp/stat-map"
  for entry in "$@"; do
    printf '%s\t%s\n' "${entry%%:*}" "${entry#*:}" >> "$tmp/stat-map"
  done
  export CMUX_TEST_STAT_MAP="$tmp/stat-map"
}

set_old_mtime() {
  local path="$1"
  local old_timestamp
  if old_timestamp="$(date -v-25H +%Y%m%d%H%M 2>/dev/null)"; then
    :
  else
    old_timestamp="$(date -d '25 hours ago' +%Y%m%d%H%M)"
  fi
  touch -t "$old_timestamp" "$path"
}

run_retention() {
  PATH="$tmp:$PATH" \
  CMUX_TUI_HOSTED_RETENTION_COUNT="$test_count" \
  CMUX_TUI_HOSTED_RETENTION_DRY_RUN="$test_dry_run" \
  CMUX_TUI_HOSTED_RETENTION_CONFIRM="$test_confirm" \
  CMUX_TUI_HOSTED_RETENTION_MAX_CANDIDATES="${test_max_candidates:-10000}" \
  CMUX_TUI_HOSTED_RETENTION_LSOF="${test_lsof_command:-$fake_lsof}" \
  CMUX_TUI_HOSTED_RETENTION_STAT="$fake_stat" \
  CMUX_TEST_MV_MODE="${test_mv_mode:-normal}" \
  CMUX_TEST_LSOF_MODE="${test_lsof_mode:-inactive}" \
  CMUX_TEST_ACTIVE_COMMIT="${test_active_commit:-}" \
  CMUX_TEST_LSOF_STATE="${test_lsof_state:-$tmp/lsof-state}" \
  CMUX_TEST_RACE_BINARY="${test_race_binary:-}" \
  CMUX_TEST_RACE_COMMIT="${test_race_commit:-}" \
  CMUX_TEST_RACE_PID_FILE="$tmp/race-pid" \
  CMUX_TEST_FIND_ARGS_FILE="$tmp/find-args" \
  CMUX_TEST_STAT_MODE="${test_stat_mode:-gnu}" \
  cmux_hosted_retention_run "$test_root/$test_current_commit" "$test_current_commit"
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
  stop_race_process
  rm -f "$tmp/lsof-state"
  make_root
  make_artifact "$current_commit"
  make_artifact "$new_commit"
  make_artifact "$active_commit"
  make_artifact "$old_commit"
  write_stat_map \
    "$current_commit:400" \
    "$new_commit:300" \
    "$active_commit:200" \
    "$old_commit:100"
  test_current_commit="$current_commit"
  test_count=1
  test_dry_run=1
  test_confirm=0
  test_lsof_mode=inactive
  test_active_commit=""
  test_stat_mode=gnu
  test_max_candidates=10000
  test_lsof_command="$fake_lsof"
  test_lsof_state="$tmp/lsof-state"
  test_race_binary=""
  test_race_commit=""
}

# The scan uses only the POSIX direct-child expression. BSD find does not
# accept GNU's -mindepth or -maxdepth predicates.
make_baseline
expect_success
[[ -s "$tmp/find-args" ]] || { echo "portable scan did not invoke find" >&2; exit 1; }
if grep -Eq '(^|[[:space:]])-(mindepth|maxdepth)([[:space:]]|$)' "$tmp/find-args"; then
  echo "portable scan passed GNU-only depth predicates" >&2
  exit 1
fi

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
assert_missing .retention.lock

# The helper is also called directly by production scripts. Its EXIT cleanup
# must remove private state when the caller does not wrap it in a conditional.
make_baseline
run_retention >"$tmp/stdout" 2>"$tmp/stderr"
assert_exists .retention-preview
test_dry_run=0
test_confirm=1
run_retention >"$tmp/stdout" 2>"$tmp/stderr"
assert_missing "$active_commit"
assert_missing "$old_commit"
assert_missing .retention.lock

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

# Adding a candidate after the preview invalidates the exact deletion plan.
make_baseline
expect_success
make_artifact "$extra_commit"
printf '%s\t%s\n' "$extra_commit" 500 >> "$tmp/stat-map"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$extra_commit"
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
printf '%s\t%s\n' "$preview_hash" "$(( $(date +%s) + 3600 ))" > "$preview"
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

# A partial lsof result is not a valid inactive decision. Preserve every
# candidate when lsof emits a name and exits nonzero.
make_baseline
expect_success
test_dry_run=0
test_confirm=1
test_lsof_mode=partial
test_active_commit="$active_commit"
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# Cleanup also fails closed when the activity tool is not available.
make_baseline
expect_success
test_dry_run=0
test_confirm=1
test_lsof_command="$tmp/missing-lsof"
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

# A preview path must be a regular file. An owned directory must not receive
# the temporary preview as a child and report success.
make_baseline
mkdir "$test_root/.retention-preview"
expect_failure 2
assert_exists .retention-preview
[[ ! -e "$test_root/.retention-preview/preview" ]] || {
  echo "preview was written inside a directory" >&2
  exit 1
}
assert_missing .retention.lock

# A process can start using an artifact after the initial batch lsof check.
# The cleanup must quarantine the directory and recheck the quarantined binary
# before deleting it, then restore an artifact that became active.
make_baseline
expect_success
test_dry_run=0
test_confirm=1
test_lsof_mode=race
test_race_binary="$test_root/$active_commit/cmux-tui"
test_race_commit="$active_commit"
expect_success
assert_exists "$active_commit"
assert_missing "$old_commit"

# A second retention process must not run concurrently with a destructive one.
make_baseline
expect_success
mkdir "$test_root/.retention.lock"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# A dead owner lock older than the recovery age is reclaimed before cleanup.
make_baseline
expect_success
(
  exit 0
) &
dead_lock_pid=$!
wait "$dead_lock_pid"
mkdir "$test_root/.retention.lock"
printf '%s\t%s\tstale-owner\n' "$dead_lock_pid" "$(( $(date +%s) - 90000 ))" > "$test_root/.retention.lock/owner"
test_dry_run=0
test_confirm=1
expect_success
assert_missing "$active_commit"
assert_missing "$old_commit"
assert_missing .retention.lock

# A crash between lock-directory creation and owner-marker publication leaves
# an empty stale directory. It must be reclaimable by age and ownership.
make_baseline
expect_success
mkdir "$test_root/.retention.lock"
set_old_mtime "$test_root/.retention.lock"
printf '.retention.lock\t100\n' >> "$tmp/stat-map"
test_dry_run=0
test_confirm=1
expect_success
assert_missing "$active_commit"
assert_missing "$old_commit"
assert_missing .retention.lock

# A malformed stale marker with no extra lock contents is also recoverable.
make_baseline
expect_success
mkdir "$test_root/.retention.lock"
printf 'malformed\n' > "$test_root/.retention.lock/owner"
set_old_mtime "$test_root/.retention.lock"
printf '.retention.lock\t100\n' >> "$tmp/stat-map"
test_dry_run=0
test_confirm=1
expect_success
assert_missing "$active_commit"
assert_missing "$old_commit"
assert_missing .retention.lock

# Reclaim must not delete a marker published after the atomic move. Restore the
# moved lock and fail closed when publication races with stale recovery.
make_baseline
mkdir "$test_root/.retention.lock"
set_old_mtime "$test_root/.retention.lock"
printf '.retention.lock\t100\n' >> "$tmp/stat-map"
test_dry_run=0
test_confirm=1
test_mv_mode=publish-marker
expect_failure 2
assert_exists .retention.lock
[[ "$(<"$test_root/.retention.lock/owner")" == published-after-move ]] || {
  echo "concurrent owner marker was not preserved" >&2
  exit 1
}

# A stale lock with unexpected contents must retain its owner marker when
# quarantine cleanup cannot remove the extra entry.
make_baseline
mkdir "$test_root/.retention.lock"
printf '999999\t1\told-token\n' > "$test_root/.retention.lock/owner"
printf x > "$test_root/.retention.lock/extra"
set_old_mtime "$test_root/.retention.lock"
printf '.retention.lock\t100\n' >> "$tmp/stat-map"
test_dry_run=0
test_confirm=1
test_mv_mode=normal
expect_failure 2
assert_exists .retention.lock
[[ "$(<"$test_root/.retention.lock/owner")" == $'999999\t1\told-token' ]] || {
  echo "stale lock owner marker was lost" >&2
  exit 1
}

# A live owner remains exclusive even when its lock is old.
make_baseline
expect_success
mkdir "$test_root/.retention.lock"
printf '%s\t%s\tlive-owner\n' "$$" "$(( $(date +%s) - 90000 ))" > "$test_root/.retention.lock/owner"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# A dead but recent owner is not reclaimed before the recovery age.
make_baseline
expect_success
(
  exit 0
) &
dead_lock_pid=$!
wait "$dead_lock_pid"
mkdir "$test_root/.retention.lock"
printf '%s\t%s\trecent-owner\n' "$dead_lock_pid" "$(date +%s)" > "$test_root/.retention.lock/owner"
test_dry_run=0
test_confirm=1
expect_failure 2
assert_exists "$active_commit"
assert_exists "$old_commit"

# A symlinked cleanup binary can make lsof report its target outside the
# artifact tree. Fail closed instead of deleting that artifact when another
# candidate produces a valid activity record.
make_baseline
mv "$test_root/$old_commit/cmux-tui" "$tmp/external-binary"
ln -s "$tmp/external-binary" "$test_root/$old_commit/cmux-tui"
expect_success
test_dry_run=0
test_confirm=1
test_lsof_mode=active
test_active_commit="$active_commit"
expect_failure 2
assert_exists "$old_commit"
assert_exists "$active_commit"

# The candidate scan has a hard upper bound, so sorting cannot grow without
# limit when a cache was never cleaned by an older script.
make_baseline
test_max_candidates=3
expect_failure 2
assert_exists "$old_commit"

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
