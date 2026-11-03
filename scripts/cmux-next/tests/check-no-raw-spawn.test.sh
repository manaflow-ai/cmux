#!/usr/bin/env bash
# check-no-raw-spawn.py (reviews 1 and 2 of pl-holder-11): a raw spawn in a
# daemon crate fails, cmux_process passes, other crates and tests are out of
# scope, and the baseline counts per file and ratchets down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-raw-spawn.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-raw-spawn.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose sources are the "path=content" pairs
# after the first argument, the baseline (may be empty).
check() {
  local baseline="$1"
  shift
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/cmux-next"
  printf '%b' "$baseline" > "$tmp/repo/scripts/cmux-next/raw-spawn-baseline.tsv"
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
TUI=cmux-tui/crates/cmux-tui/src/other.rs
PTY=cmux-tui/crates/cmux-pty/src/spawn.rs
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

fail "std Command by path" "" "$CORE=    let out = std::process::Command::new(\"git\").output();"
fail "std Command imported" "" "$CORE=use std::process::Command;
fn f() { Command::new(\"git\").spawn(); }"
fail "std Command in a use group" "" "$CORE=use std::process::{Command, Stdio};"
fail "std Command in a multi-line use group" "" "$CORE=use std::process::{
    Command,
    Stdio,
};"
fail "Command through a glob" "" "$CORE=use super::*;
fn f() { let mut c = Command::new(\"cat\"); }"
fail "tokio Command" "" "$TUI=    let c = tokio::process::Command::new(\"sh\");"
fail "a pre_exec hook" "" "$PTY=    unsafe { command.pre_exec(|| Ok(())) };"
fail "libc::fork" "" "$CORE=    let pid = unsafe { libc::fork() };"
fail "libc::posix_spawnp" "" "$CORE=    unsafe { libc::posix_spawnp(&mut pid, p, a, b, c, d) };"

pass "cmux_process imported by name" "" "$CORE=use cmux_process::{Command, Stdio};
fn f() { Command::new(\"git\").output(); }"
pass "cmux_process by path" "" "$CORE=fn f() { cmux_process::Command::new(\"git\").output(); }"
pass "a PtyCommand" "" "$CORE=    let c = cmux_pty::PtyCommand::new(\"sh\");"
pass "a comment" "" "$CORE=    // std::process::Command::new(\"git\") was the old way"
pass "a test file" "" "cmux-tui/crates/cmux-tui-core/src/fixture_tests.rs=    std::process::Command::new(\"git\");"
pass "an integration test" "" "cmux-tui/crates/cmux-tui-core/tests/it.rs=    std::process::Command::new(\"git\");"
pass "another crate (a separate process)" "" "cmux-tui/crates/acpmux/src/lib.rs=    std::process::Command::new(\"git\");"

ROW="$CORE\t1\tPL-daemon\n"
pass "a baselined site" "$ROW" "$CORE=    std::process::Command::new(\"git\");"
fail "one more site than the baseline" "$ROW" "$CORE=    std::process::Command::new(\"git\");
    std::process::Command::new(\"gh\");"
fail "a site moved to a file with no row" "$ROW" \
  "$CORE=fn f() {}" "$TUI=    std::process::Command::new(\"git\");"
# Fewer sites than the row: a note to lower it, not a refusal (the hook reads
# the installed baseline, so a refusal would refuse every push that moves a site).
pass "fewer sites than the baseline (a note to lower the row)" "$ROW" "$CORE=fn f() {}"
grep -q "Lower its row" "$tmp/err" || { echo "FAIL: the ratchet must say to lower the row" >&2; exit 1; }
check "x\tnot-a-number\towner\n" "$CORE=fn f() {}" && { echo "FAIL: a bad baseline row must be refused" >&2; exit 1; }

echo "check-no-raw-spawn tests: ok"
