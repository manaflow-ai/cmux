#!/usr/bin/env bash
# check-feed-session-key.py (review of #41240, F1): on the feed path a raw
# sessionId read or a hand-made peer/id key fails; writing sessionId into a
# request, a comment, an allowed line and files off the feed path pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-feed-session-key.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-feed-session-key.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose sources are the "path=content" pairs.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo"
  local pair
  for pair in "$@"; do
    mkdir -p "$tmp/repo/$(dirname "${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$tmp/repo/${pair%%=*}"
  done
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
S=Packages/macOS/CmuxNext/Sources
BRIDGE=$S/CmuxNextApp/Feed/AcpmuxPermissionFeedBridge.swift
SIBLING=$S/CmuxNextApp/Feed/Sub/OtherFeedPoster.swift
LINE=$S/CmuxNextAgentPane/Approvals/AgentDialogLine.swift
READS=$S/CmuxNextAgentPane/AcpmuxPendingReads.swift
GATE=$S/CmuxNextAgentPane/AcpmuxSessionListGate.swift
PANE=$S/CmuxNextAgentPane/AcpmuxPaneSessions.swift
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

fail "the bridge keys a notice on the raw id (#41240 F1)" \
  "$BRIDGE=            guard let session = params[\"sessionId\"] as? String else { return }"
fail "a withdraw keyed on the raw id" \
  "$BRIDGE=               let session = params [ \"sessionId\" ] as? String {"
fail "a sibling feed file in a subfolder" "$SIBLING=let id = row[\"sessionId\"] as? String"
fail "the dialog desk's prompt list" "$LINE=let session = summary[\"sessionId\"] as? String"
fail "the recovery list's dedupe key built by hand" \
  "$GATE=                let key = \"\\(row[\"peer\"] as? String ?? \"\")/\\(id)\""
fail "a raw read after code on a line with a string holding //" \
  "$BRIDGE=let u = \"a//b\"; let s = params[\"sessionId\"] as? String"

pass "the shared key" "$BRIDGE=guard let session = AcpmuxPendingReads.sessionKey(params) else { return }"
pass "sessionId written into a request" "$BRIDGE=await call(\"_acpmux/info\", [\"sessionId\": session])"
pass "a comment" "$BRIDGE=    // params[\"sessionId\"] named no peer"
pass "a trailing comment" "$BRIDGE=let x = 1 // not params[\"sessionId\"]"
pass "an allowed line (sessionKey's own body)" \
  "$READS=        guard let id = row[\"sessionId\"] as? String else { return nil } // feed-key-allow: the one key"
pass "a file off the feed path" "$PANE=guard let session = params[\"sessionId\"] as? String else { return false }"
pass "no feed files at all"

code=0
python3 -I "$CHECK" a b >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || { echo "FAIL: two roots must be a usage error (got $code)" >&2; exit 1; }

echo "check-feed-session-key tests: ok"
