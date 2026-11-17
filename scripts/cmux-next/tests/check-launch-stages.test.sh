#!/usr/bin/env bash
# check-launch-stages.py (LAUNCH-STAGES): the Swift stage-0 allowlist must match
# Rust's, a stage-0 task off the allowlist fails, a duplicate task fails, the
# real tree passes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-launch-stages.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-launch-stages.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
RUST=cmux-tui/crates/cmux-launch-record/src/lib.rs
SWIFT=Packages/macOS/CmuxNext/Sources/CmuxNextControl/LaunchStageRegistry.swift

RUST_OK='pub const STAGE_ZERO_ALLOWLIST: &[&str] = &[
    "read_launch_record",
    "make_window",
];'
swift() {
  printf '%s\n' "public enum LaunchStageRegistry {
    public static let stageZeroAllowlist: Set<String> = [
        $1
    ]
    public static let finishLaunching: [LaunchTask] = [
        $2
    ]
}"
}

# check RUST SWIFT: runs the guard on a repo root holding only those two files.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$RUST")" "$tmp/repo/$(dirname "$SWIFT")"
  [[ -n "$1" ]] && printf '%s\n' "$1" > "$tmp/repo/$RUST"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$tmp/repo/$SWIFT"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
pass() { check "$2" "$3" || { echo "FAIL: must pass: $1" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$2" "$3" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $1" >&2; cat "$tmp/err" >&2; exit 1; }
}

ALLOW='"read_launch_record", "make_window",'
pass "matching lists, stage-0 tasks on the list" "$RUST_OK" \
  "$(swift "$ALLOW" '.init("read_launch_record", .shell), .init("make_window", .shell), .init("start_cloud", .rest),')"
fail "a Swift allowlist with an extra name" "$RUST_OK" \
  "$(swift "$ALLOW \"start_daemon\"," '.init("make_window", .shell),')"
fail "a Swift allowlist missing a name" "$RUST_OK" \
  "$(swift '"make_window",' '.init("make_window", .shell),')"
fail "a stage-0 task off the allowlist" "$RUST_OK" \
  "$(swift "$ALLOW" '.init("make_window", .shell), .init("start_daemon", .shell),')"
fail "a task declared twice" "$RUST_OK" \
  "$(swift "$ALLOW" '.init("start_cloud", .rest), .init("start_cloud", .visible),')"
fail "an unknown stage" "$RUST_OK" \
  "$(swift "$ALLOW" '.init("start_cloud", .later),')"
fail "no task list" "$RUST_OK" 'public enum LaunchStageRegistry {}'
fail "a missing Rust file" "" "$(swift "$ALLOW" '.init("make_window", .shell),')"

python3 -I "$CHECK" "$ROOT_DIR" || { echo "FAIL: the checked-in tree must pass" >&2; exit 1; }
echo ok
