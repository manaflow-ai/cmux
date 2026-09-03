#!/bin/bash
# Regression cases for lint-remote-tmux-no-polling.sh, run against a fixture tree.
set -u
cd "$(dirname "$0")/.." || exit 1
LINT=scripts/lint-remote-tmux-no-polling.sh
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi; }
fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
mkdir -p "$fx/Sources"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func alreadyThere() {
    try await ContinuousClock().sleep(for: .milliseconds(5))
}
func usesGlobalQueue() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { }
}
SWIFT
base="$fx/baseline.txt"

# 1. `.asyncAfter(` on a called receiver is a wait, whatever the queue expression looks like.
: > "$base"
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "global().asyncAfter is caught" 1 "$rc"
chk "global().asyncAfter names its function" 1 "$(grep -c "usesGlobalQueue" <<<"$out")"

# 2. --write-baseline records each wait individually, and the tree is then clean.
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" --write-baseline >/dev/null
chk "baseline has one entry per wait" 2 "$(wc -l < "$base" | tr -d ' ')"
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "baselined tree is clean" 0 "$?"

# 3. A second wait inside an already-baselined function is NEW and must fail.
cat >> "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func alreadyThereToo() {}
SWIFT
python3 - "$fx/Sources/RemoteTmuxFixture.swift" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("    try await ContinuousClock().sleep(for: .milliseconds(5))\n", "    try await ContinuousClock().sleep(for: .milliseconds(5))\n    try await Task.sleep(nanoseconds: 1)\n",1)
open(p,'w').write(s)
PY
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "a second sleep in a baselined function fails" 1 "$rc"
chk "and the report names that sleep" 1 "$(grep -c "Task.sleep(nanoseconds: 1)" <<<"$out")"

# 4. Moving the baselined wait to another line is not a new wait.
python3 - "$fx/Sources/RemoteTmuxFixture.swift" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("    try await Task.sleep(nanoseconds: 1)\n","",1)
open(p,'w').write("// a leading comment shifts every line\n"+s)
PY
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "line moves do not fail" 0 "$?"

# 5. A scan error must not read as clean.
chmod 000 "$fx/Sources/RemoteTmuxFixture.swift"
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1; rc=$?
chmod 644 "$fx/Sources/RemoteTmuxFixture.swift"
if [ "$(id -u)" -eq 0 ]; then echo "skip: running as root, unreadable-file case not testable"; else chk "unreadable source fails closed with exit 2" 2 "$rc"; fi

echo "lint-remote-tmux-no-polling.test: $pass passed, $fail failed"
exit $(( fail > 0 ))
