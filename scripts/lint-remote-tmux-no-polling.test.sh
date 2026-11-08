#!/bin/bash
# Regression cases for lint-remote-tmux-no-polling.sh, run against a fixture tree.
set -u
cd "$(dirname "$0")/.." || exit 1
# LINT_UNDER_TEST points the cases at another copy of the lint, to check that they fail on a broken one.
LINT="${LINT_UNDER_TEST:-scripts/lint-remote-tmux-no-polling.sh}"
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

# 6. One baseline entry authorises ONE wait. A second IDENTICAL wait in the same function
# shares the key, so matching without counting would let the new one ride the old entry.
rm -f "$base"; : > "$base"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func twinWaits() {
    try await Task.sleep(nanoseconds: 7)
}
SWIFT
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" --write-baseline >/dev/null
chk "one wait baselines one entry" 1 "$(wc -l < "$base" | tr -d ' ')"
python3 - "$fx/Sources/RemoteTmuxFixture.swift" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("    try await Task.sleep(nanoseconds: 7)\n",
            "    try await Task.sleep(nanoseconds: 7)\n    try await Task.sleep(nanoseconds: 7)\n",1)
open(p,'w').write(s)
PY2
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "a duplicate of a baselined wait fails" 1 "$?"

# 7. Infrastructure failures fail closed rather than reporting a clean tree.
LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$fx/no/such/dir/baseline.txt" \
  bash "$LINT" --write-baseline >/dev/null 2>&1
chk "an unwritable baseline exits 2" 2 "$?"

# 8. When the lint cannot record that an allowance was used, it must fail closed. Otherwise
# every identical wait keeps reading "0 used" and the duplicate from case 6 passes. A mktemp
# shim hands the lint a directory as its second temp file, so appends to that ledger fail.
mkdir -p "$fx/bin" "$fx/ledger-dir"
cat > "$fx/bin/mktemp" <<SHIM
#!/bin/bash
n=\$(( \$(cat "$fx/bin/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$fx/bin/count"
if [ "\$n" -eq 2 ]; then echo "$fx/ledger-dir"; else exec /usr/bin/mktemp "\$@"; fi
SHIM
chmod +x "$fx/bin/mktemp"
PATH="$fx/bin:$PATH" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "an unwritable allowance ledger exits 2" 2 "$?"

# 9. A clock held in a property sleeps like any other clock. The pattern is lexical, so it has
# to catch `.sleep(` on any receiver, not only the `ContinuousClock()` constructor spelling.
rm -f "$base"; : > "$base"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func usesStoredClock() {
    try await clock.sleep(for: .seconds(1))
}
SWIFT
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "a stored clock's sleep is caught" 1 "$rc"
chk "and the report names its function" 1 "$(grep -c "usesStoredClock" <<<"$out")"

# 10. The scan's own plumbing must not be able to hide hits. If the lint could not create a
# scratch file next to its temp files, a redirect failing before grep ran used to read as
# "no matches". Temp files land in a directory that turns read-only after both are created.
mkdir -p "$fx/ro-tmp" "$fx/bin10"
cat > "$fx/bin10/mktemp" <<SHIM
#!/bin/bash
n=\$(( \$(cat "$fx/bin10/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$fx/bin10/count"
f="$fx/ro-tmp/tmp\$n"; : > "\$f"
[ "\$n" -eq 2 ] && chmod 555 "$fx/ro-tmp"
echo "\$f"
SHIM
chmod +x "$fx/bin10/mktemp"
out="$(PATH="$fx/bin10:$PATH" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chmod 755 "$fx/ro-tmp"
if [ "$(id -u)" -eq 0 ]; then echo "skip: running as root, read-only temp dir case not testable"; else
  chk "a read-only temp dir cannot turn hits into a clean run" 1 "$rc"
  chk "and the hit is still reported" 1 "$(grep -c "usesStoredClock" <<<"$out")"
fi

# 11. A documented exception covers ONE wait, the same way a baseline entry does. A second wait
# added to a documented function is new and must fail.
rm -f "$base"; : > "$base"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func documentedBackoff() {
    try await ContinuousClock().sleep(for: .seconds(delay))
}
SWIFT
allow="$fx/allow.txt"
printf '%s\n%s\n' \
  "$fx/Sources/RemoteTmuxFixture.swift:documentedBackoff:try await ContinuousClock().sleep(for: .seconds(delay))" \
  "fixture: the host is unreachable and nothing local can observe it coming back" > "$allow"
LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "a documented wait passes" 0 "$?"
python3 - "$fx/Sources/RemoteTmuxFixture.swift" <<'PY11'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("    try await ContinuousClock().sleep(for: .seconds(delay))\n",
            "    try await ContinuousClock().sleep(for: .seconds(delay))\n    usleep(10)\n",1)
open(p,'w').write(s)
PY11
out="$(LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "a second wait in a documented function fails" 1 "$rc"
chk "and the report names the new wait" 1 "$(grep -c "usleep(10)" <<<"$out")"
LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" --write-baseline >/dev/null 2>&1
chk "--write-baseline records the new wait and leaves the documented one out" 1 "$(wc -l < "$base" | tr -d ' ')"
chk "and the one entry is the new wait" 1 "$(grep -c "usleep(10)" "$base")"
# An identical copy of the documented wait is a second wait. Matching without counting would
# let it ride the first one's exception.
: > "$base"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func documentedBackoff() {
    try await ContinuousClock().sleep(for: .seconds(delay))
    try await ContinuousClock().sleep(for: .seconds(delay))
}
SWIFT
out="$(LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "a duplicate of a documented wait fails" 1 "$rc"
chk "and exactly one of the twins is reported" 1 "$(grep -c "time-based wait in 'documentedBackoff'" <<<"$out")"
LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" --write-baseline >/dev/null 2>&1
chk "--write-baseline counts too: one twin is documented, the other is recorded" 1 "$(wc -l < "$base" | tr -d ' ')"
: > "$base"
# Replacing the documented wait with a different one is a new wait too: the exception names
# the wait, not the function.
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func documentedBackoff() {
    usleep(11)
}
SWIFT
out="$(LINT_ALLOW_FILE="$allow" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "a different wait in a documented function fails" 1 "$rc"
chk "and the report names it" 1 "$(grep -c "usleep(11)" <<<"$out")"
# A list that cannot be read as wait-and-reason pairs is a broken lint, not an empty list.
printf '%s\n' "$fx/Sources/RemoteTmuxFixture.swift:documentedBackoff:usleep(11)" > "$fx/allow-odd.txt"
out="$(LINT_ALLOW_FILE="$fx/allow-odd.txt" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "an exception without a reason exits 2" 2 "$rc"
chk "and says why" 1 "$(grep -c "ALLOW must hold a wait line and a reason line" <<<"$out")"
LINT_ALLOW_FILE="$fx/no-such-allow.txt" LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" >/dev/null 2>&1
chk "a missing exception list exits 2" 2 "$?"

# 12. The scope is every product Swift file with RemoteTmux in its path, not only the files
# whose name starts with it. Tests stay out of scope.
rm -f "$base"; : > "$base"; rm -f "$fx/Sources/RemoteTmuxFixture.swift"
mkdir -p "$fx/Sources/Nested/RemoteTmux" "$fx/Sources/Pkg/Tests/RemoteTmuxTests"
cat > "$fx/Sources/TerminalController+RemoteTmux.swift" <<'SWIFT'
func extensionFileWait() {
    try await Task.sleep(nanoseconds: 3)
}
SWIFT
cat > "$fx/Sources/Nested/RemoteTmux/LayoutThing.swift" <<'SWIFT'
func nestedDirectoryWait() {
    usleep(4)
}
SWIFT
cat > "$fx/Sources/Pkg/Tests/RemoteTmuxTests/RemoteTmuxTimingTests.swift" <<'SWIFT'
func testMayDriveTime() {
    try await Task.sleep(nanoseconds: 5)
}
SWIFT
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "waits outside the RemoteTmux basename prefix fail" 1 "$rc"
chk "an extension file is scanned" 1 "$(grep -c "extensionFileWait" <<<"$out")"
chk "a nested RemoteTmux directory is scanned" 1 "$(grep -c "nestedDirectoryWait" <<<"$out")"
chk "tests stay out of scope" 0 "$(grep -c "testMayDriveTime" <<<"$out")"
# A linked file and a linked directory are scanned like any other.
mkdir -p "$fx/elsewhere/RemoteTmuxLinkedDir"
cat > "$fx/elsewhere/linked-file.swift" <<'SWIFT'
func linkedFileWait() {
    usleep(6)
}
SWIFT
cat > "$fx/elsewhere/RemoteTmuxLinkedDir/Inner.swift" <<'SWIFT'
func linkedDirectoryWait() {
    usleep(7)
}
SWIFT
ln -s "$fx/elsewhere/linked-file.swift" "$fx/Sources/RemoteTmuxLinked.swift"
ln -s "$fx/elsewhere/RemoteTmuxLinkedDir" "$fx/Sources/RemoteTmuxLinkedDir"
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"
chk "a symlinked file is scanned" 1 "$(grep -c "linkedFileWait" <<<"$out")"
chk "a symlinked directory is scanned" 1 "$(grep -c "linkedDirectoryWait" <<<"$out")"
rm -f "$fx/Sources/RemoteTmuxLinked.swift" "$fx/Sources/RemoteTmuxLinkedDir"
# The default roots, run the way CI runs it: a copy of the lint inside a fixture repository,
# with no LINT_SCOPE_DIR, must scan Sources and Packages.
mkdir -p "$fx/repo/scripts" "$fx/repo/Sources" "$fx/repo/Packages/P/Sources/P/RemoteTmux"
cp "$LINT" "$fx/repo/scripts/lint-remote-tmux-no-polling.sh"
cat > "$fx/repo/Sources/RemoteTmuxA.swift" <<'SWIFT'
func sourcesRootWait() {
    usleep(1)
}
SWIFT
cat > "$fx/repo/Packages/P/Sources/P/RemoteTmux/B.swift" <<'SWIFT'
func packagesRootWait() {
    usleep(2)
}
SWIFT
out="$(env -u LINT_SCOPE_DIR LINT_BASELINE_FILE="$base" bash "$fx/repo/scripts/lint-remote-tmux-no-polling.sh" 2>&1)"; rc=$?
chk "the default roots fail on new waits" 1 "$rc"
chk "Sources is a default root" 1 "$(grep -c "sourcesRootWait" <<<"$out")"
chk "Packages is a default root" 1 "$(grep -c "packagesRootWait" <<<"$out")"

# 13. An empty scope is a broken scan, not a clean tree.
mkdir -p "$fx/empty"
out="$(LINT_SCOPE_DIR="$fx/empty" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1 </dev/null)"; rc=$?
chk "an empty scope exits 2" 2 "$rc"
chk "and says nothing was found" 1 "$(grep -c "no remote-tmux sources found" <<<"$out")"

# 14. A space before the parenthesis is the same call. A parenthesis on the NEXT line is not a
# call in Swift (the compiler reports the function as unused), so there is no such shape to
# catch. Names that only look like a wait, an enum case, an injected sleep closure being
# stored, and a comment are not waits.
rm -rf "$fx/Sources"; mkdir -p "$fx/Sources"; : > "$base"
cat > "$fx/Sources/RemoteTmuxFixture.swift" <<'SWIFT'
func spacedParenthesis() {
    usleep (5)
    DispatchQueue.main.asyncAfter (deadline: .now() + 1) { }
    try await clock.sleep (for: .seconds(1))
}
func mentionsNothing() {
    // a comment that names Task.sleep( and .asyncAfter( is not a wait
    let sleepiness = 1
    self.sleepiness = 2
    glow.asyncAfterglow()
    musleep(3)
    powerState = .sleep
    self.sleep = sleep
}
SWIFT
out="$(LINT_SCOPE_DIR="$fx/Sources" LINT_BASELINE_FILE="$base" bash "$LINT" 2>&1)"; rc=$?
chk "spaced calls fail" 1 "$rc"
chk "all three spaced calls are caught" 3 "$(grep -c "in 'spacedParenthesis'" <<<"$out")"
chk "lookalikes, an enum case, a stored closure and a comment are not waits" 0 "$(grep -c "mentionsNothing" <<<"$out")"

echo "lint-remote-tmux-no-polling.test: $pass passed, $fail failed"
exit $(( fail > 0 ))
