#!/usr/bin/env bash
# check-session-info-names.py: an Inspector identifier, class or file name in Session Info's code
# fails; comments, the kept saved and wire names and the real tree pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-session-info-names.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-session-info-names.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
DIR=webviews/src/agent-session/acpmux/session-info

# Runs the guard on a repo root whose only source is $2 at path $1: 0 clean, 1 a finding naming it.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  local code=0
  python3 -I "$CHECK" --root "$tmp/repo" >"$tmp/out" 2>&1 || code=$?
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/out"; then code=3; fi
  return "$code"
}
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/out" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/out" >&2; exit 1; }
}

fail "$DIR/SessionInfo.tsx" "an Inspector identifier" 'export function useChatInspector() {}'
fail "$DIR/sessionInfo.css" "an inspector class" '.acpmux-chat-inspector-row { gap: 2px; }'
fail "$DIR/inspectorState.ts" "an inspector file name" 'export const x = 1;'
fail "webviews/test/session-info-x.test.ts" "an inspector local in a test" 'const inspector = 1;'

pass "$DIR/SessionInfo.tsx" "a comment naming the event Inspector" $'// the event Inspector covers the chat\nconst x = 1;'
pass "$DIR/sessionInfoState.ts" "a saved localStorage key" 'const OPEN_KEY = "cmux.agentPane.inspector.open";'
pass "$DIR/SessionInfo.gallery.tsx" "a gallery entry id" 'id: "agent-pane.chat-inspector",'
pass "$DIR/Motion.gallery.ts" "the header state wire name" 'const native = { "pane.tabState": { inspector: true } };'
pass "webviews/test/session-info-name.test.ts" "the exempt naming test" 'const INSPECTOR = /inspector/i;'
pass "webviews/src/agent-session/acpmux/Inspector.tsx" "the event Inspector outside the panel" 'export function Inspector() {}'

python3 -I "$CHECK" --self-test >/dev/null
# The real tree is clean.
python3 -I "$CHECK" >/dev/null
echo "check-session-info-names: ok"
