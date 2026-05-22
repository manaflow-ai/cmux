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
assert_contains "$out" "dry-run: cmux read-screen --workspace workspace:7 --surface surface:9"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 escape"
assert_contains "$out" "new\\ goal"
assert_contains "$out" "dry-run: cmux send-key --workspace workspace:7 --surface surface:9 enter"

err_file="$(mktemp)"
if "$SCRIPT" --surface surface:9 unknown workspace:7 2>"$err_file"; then
  printf 'unknown command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'unknown command: unknown' "$err_file"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CMUX_FAKE_LOG"
if [[ "$1" == "read-screen" ]]; then
  printf '%s\n' "${CMUX_FAKE_SCREEN:-composer ready}"
fi
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
  "$SCRIPT" --apply --surface surface:5 swap workspace:2 "new goal"

grep -q 'read-screen --workspace workspace:2 --surface surface:5' "$tmp/cmux.log"
grep -q 'send --workspace workspace:2 --surface surface:5 new goal' "$tmp/cmux.log"
grep -q 'send-key --workspace workspace:2 --surface surface:5 enter' "$tmp/cmux.log"
if grep -q 'ctrl+c' "$tmp/cmux.log"; then
  printf 'swap should not send ctrl+c\n' >&2
  exit 1
fi
grep -q 'state=active' "$tmp/goals/workspace:2.goal"
grep -q 'objective=new goal' "$tmp/goals/workspace:2.goal"

CMUX_FAKE_LOG="$tmp/cmux.log" \
CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 pause workspace:2

grep -q 'send-key --workspace workspace:2 --surface surface:5 escape' "$tmp/cmux.log"
grep -q 'state=paused' "$tmp/goals/workspace:2.goal"
grep -q 'objective=new goal' "$tmp/goals/workspace:2.goal"

CMUX_FAKE_LOG="$tmp/cmux.log" \
CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 resume workspace:2

grep -q 'send --workspace workspace:2 --surface surface:5 continue with the current goal' "$tmp/cmux.log"
grep -q 'state=active' "$tmp/goals/workspace:2.goal"
grep -q 'objective=new goal' "$tmp/goals/workspace:2.goal"

if CMUX_FAKE_SCREEN='Working (1s - esc to interrupt)' \
  CMUX_FAKE_LOG="$tmp/cmux.log" \
  CMUX_MANAGER_GOAL_DIR="$tmp/goals" \
  PATH="$tmp/bin:$PATH" \
  "$SCRIPT" --apply --surface surface:5 swap workspace:2 "pending goal" 2>"$tmp/swap.err"; then
  printf 'busy swap unexpectedly succeeded\n' >&2
  exit 1
fi

grep -q 'send-key --workspace workspace:2 --surface surface:5 escape' "$tmp/cmux.log"
if grep -q 'send --workspace workspace:2 --surface surface:5 pending goal' "$tmp/cmux.log"; then
  printf 'busy swap should not send prompt before composer is ready\n' >&2
  exit 1
fi
grep -q 'state=swap-pending' "$tmp/goals/workspace:2.goal"
grep -q 'objective=pending goal' "$tmp/goals/workspace:2.goal"

printf 'ok\n'
