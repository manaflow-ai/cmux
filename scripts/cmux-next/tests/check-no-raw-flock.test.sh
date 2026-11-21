#!/usr/bin/env bash
# check-no-raw-flock.py (the lock-by-close audit, lane c-agenthost): a raw
# file-lock call in cmux-tui product code fails, cmux_file_lock passes, the
# cmux-file-lock crate, tests and comments are out of scope, and the baseline
# counts per file and ratchets down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-raw-flock.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-raw-flock.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose sources are the "path=content" pairs
# after the first argument, the baseline (may be empty).
check() {
  local baseline="$1"
  shift
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/cmux-next"
  printf '%b' "$baseline" > "$tmp/repo/scripts/cmux-next/raw-flock-baseline.tsv"
  local pair
  for pair in "$@"; do
    mkdir -p "$tmp/repo/$(dirname "${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$tmp/repo/${pair%%=*}"
  done
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
CORE=cmux-tui/crates/cmux-tui-core/src/fixture.rs
AMX=cmux-tui/crates/acpmux/src/other.rs
pass() {
  local what="$1"
  shift
  check "$@" || { echo "FAIL: must pass: $what" >&2; cat "$tmp/err" >&2; exit 1; }
}
fail() {
  local what="$1"
  shift
  local code=0
  check "$@" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $what" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "libc::flock" "" "$CORE=    unsafe { libc::flock(fd, libc::LOCK_EX) };"
fail "an imported flock" "" "$CORE=    let rc = unsafe { flock(fd, LOCK_EX | LOCK_NB) };"
fail "rustix flock" "" "$AMX=    rustix::fs::flock(&file, FlockOperation::LockExclusive)?;"
fail "nix FlockArg" "" "$AMX=    nix::fcntl::Flock::lock(file, FlockArg::LockExclusive)?;"
fail "fs4 FileExt::lock" "" "$CORE=    fs4::FileExt::lock(&file)?;"
fail "fs4 FileExt::try_lock" "" "$CORE=    match fs4::FileExt::try_lock(&file) {}"
fail "std File::lock by path" "" "$CORE=    std::fs::File::lock(&file)?;"
fail "a lock_exclusive method" "" "$CORE=    file.lock_exclusive()?;"
fail "a try_lock_shared method" "" "$AMX=    matches!(file.try_lock_shared(), Err(_))"
fail "another crate is in scope too" "" "cmux-tui/crates/cmux-remote/src/lib.rs=    file.lock_shared()?;"

pass "cmux_file_lock" "" "$CORE=    let held = cmux_file_lock::FileLock::take(file, Kind::Exclusive)?;"
pass "a mutex lock and try_lock" "" "$CORE=    let a = state.lock(); let b = state.try_lock();"
pass "a helper definition named flock" "" "$CORE=fn flock(fd: i32) -> i32 { 0 }"
pass "an unlock" "" "$CORE=    let _ = fs4::FileExt::unlock(&file);"
pass "a comment" "" "$CORE=    // libc::flock(fd, LOCK_EX) was the old way"
pass "the cmux-file-lock crate" "" "cmux-tui/crates/cmux-file-lock/src/lib.rs=    unsafe { libc::flock(fd, libc::LOCK_EX) };"
pass "a test file" "" "cmux-tui/crates/cmux-tui-core/src/fixture_tests.rs=    unsafe { libc::flock(fd, libc::LOCK_EX) };"
pass "an integration test" "" "cmux-tui/crates/cmux-tui-core/tests/it.rs=    file.lock_exclusive()?;"

ROW="$CORE\t1\tc-agenthost (unlocking Drop)\n"
pass "a baselined site" "$ROW" "$CORE=    file.lock_exclusive()?;"
fail "one more site than the baseline" "$ROW" "$CORE=    file.lock_exclusive()?;
    file.lock_shared()?;"
fail "a site moved to a file with no row" "$ROW" "$CORE=fn f() {}" "$AMX=    file.lock_exclusive()?;"
# Fewer sites than the row: a note to lower it, not a refusal (the hook reads
# the installed baseline, so a refusal would refuse every push that moves a site).
pass "fewer sites than the baseline (a note to lower the row)" "$ROW" "$CORE=fn f() {}"
grep -q "Lower its row" "$tmp/err" || { echo "FAIL: the ratchet must say to lower the row" >&2; exit 1; }
check "x\tnot-a-number\towner\n" "$CORE=fn f() {}" && { echo "FAIL: a bad baseline row must be refused" >&2; exit 1; }

echo "check-no-raw-flock tests: ok"
