#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/cmux-manager-codex-goal.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n%s\n' "$haystack" >&2
    exit 1
  fi
}

out="$("$SCRIPT" --surface surface:9 set workspace:7 "write the doc")"
assert_contains "$out" "dry-run: cmux send --workspace workspace:7 --surface surface:9"
assert_contains "$out" "write\\ the\\ doc"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 enter"
assert_contains "$out" "state=active"

out="$("$SCRIPT" --surface surface:9 pause workspace:7)"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 escape"
assert_contains "$out" "state=paused"

out="$("$SCRIPT" --surface surface:9 resume workspace:7)"
assert_contains "$out" "continue\\ with\\ the\\ current\\ goal"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 enter"

out="$("$SCRIPT" --surface surface:9 swap workspace:7 "new goal")"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 ctrl+c"
assert_contains "$out" "new\\ goal"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 enter"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CMUX_FAKE_LOG"
SH
chmod +x "$tmp/bin/cmux"

CMUX_FAKE_LOG="$tmp/cmux.log" \
CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 set workspace:2 "ship it"

grep -q 'send --workspace workspace:2 --surface surface:5 ship it' "$tmp/cmux.log"
grep -q 'send-key --workspace workspace:2 --surface surface:5 enter' "$tmp/cmux.log"
grep -q 'workspace=workspace:2' "$tmp/goals/workspace:2.goal"
grep -q 'state=active' "$tmp/goals/workspace:2.goal"
grep -q 'objective=ship it' "$tmp/goals/workspace:2.goal"

CMUX_FAKE_LOG="$tmp/cmux.log" \
CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 pause workspace:2

grep -q 'send-key --workspace workspace:2 --surface surface:5 escape' "$tmp/cmux.log"
grep -q 'state=paused' "$tmp/goals/workspace:2.goal"
grep -q 'objective=ship it' "$tmp/goals/workspace:2.goal"

CMUX_FAKE_LOG="$tmp/cmux.log" \
CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 resume workspace:2

grep -q 'send --workspace workspace:2 --surface surface:5 continue with the current goal' "$tmp/cmux.log"
grep -q 'state=active' "$tmp/goals/workspace:2.goal"
grep -q 'objective=ship it' "$tmp/goals/workspace:2.goal"

printf 'ok\n'
