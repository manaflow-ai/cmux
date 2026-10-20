#!/usr/bin/env bash
# fast-tier.py: the cmux NEXT PR fast tier runs every registered entry, gates
# on a failure, calls a fail-then-pass FLAKY (a failure, never a silent retry),
# reports a quarantined entry without gating on it, stops an entry at its time
# cap, refuses an entry with no owner, and in --repeat (admission) mode fails
# an entry whose result changes between runs. --dry-run prints one build per
# Swift package and one test command per entry.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$ROOT_DIR/scripts/cmux-next/fast-tier.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-fast-tier.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/root/bin"
cat > "$tmp/root/bin/pass.sh" <<'EOF'
exit 0
EOF
cat > "$tmp/root/bin/fail.sh" <<'EOF'
echo "MATRIX split.close.zoom: pane count 3, expected 2"
exit 1
EOF
# Fails on its first run, passes after: the state file counts runs.
cat > "$tmp/root/bin/flaky.sh" <<'EOF'
n=$(cat "$1" 2>/dev/null || echo 0); echo $((n + 1)) > "$1"
[ "$n" -ge 1 ]
EOF
cat > "$tmp/root/bin/slow.sh" <<'EOF'
sleep 5
EOF
# Like swift test: a child (xctest) that outlives its parent and keeps the
# output pipe open. cmux19, run 39360407187: three entries timed out twice
# each (the run and the classify run) and left six xctest processes behind.
cat > "$tmp/root/bin/hang-child.sh" <<'EOF'
sleep 30 &
echo $! >> "$1"
# SwiftPM starts xctest in a process group of its own: killing the entry's
# group alone misses it.
python3 -c 'import os, time; os.setpgid(0, 0); time.sleep(30)' &
echo $! >> "$1"
wait
EOF

registry() { printf '%s\n' "$1" > "$tmp/registry.json"; }
quarantine() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' '{"entries": []}'
  fi > "$tmp/quarantine.json"
}
entry() { printf '{"name": "%s", "kind": "script", "path": "bin/%s", "args": %s, "owner": "op-test", "bead": "cx-test"}' "$1" "$2" "${3:-[]}"; }
run() {
  set +e
  out="$(python3 -I "$RUNNER" --root "$tmp/root" --registry "$tmp/registry.json" --quarantine "$tmp/quarantine.json" --max-seconds 2 "$@" 2>&1)"
  status=$?
  set -e
}
expect() {
  local what="$1" want_status="$2" pattern="$3"
  if [ "$status" -ne "$want_status" ] || ! grep -Eq -- "$pattern" <<<"$out"; then
    echo "FAIL: $what (exit $status, want $want_status, pattern $pattern)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

quarantine
registry "{\"entries\": [$(entry ok pass.sh), $(entry ok2 pass.sh)]}"
run
expect "every entry passing passes the tier" 0 "^FAST-TIER PASS ok2 "

registry "{\"entries\": [$(entry ok pass.sh), $(entry broken fail.sh)]}"
run
expect "a failing entry fails the tier" 1 "^FAST-TIER FAIL broken .*owner=op-test bead=cx-test"
expect "a failure keeps the entry's own failure line" 1 "MATRIX split.close.zoom"

rm -f "$tmp/state"
registry "{\"entries\": [$(entry wobbly flaky.sh "[\"$tmp/state\"]")]}"
run
expect "a fail-then-pass entry is FLAKY and fails the tier" 1 "^FAST-TIER FLAKY wobbly .*quarantine"

quarantine '{"entries": [{"name": "broken", "owner": "op-test", "bead": "cx-test", "since": "2026-10-13"}]}'
registry "{\"entries\": [$(entry ok pass.sh), $(entry broken fail.sh)]}"
run
expect "a quarantined failure is reported but does not gate" 0 "^FAST-TIER QUARANTINED-FAIL broken "
quarantine

registry "{\"entries\": [$(entry stuck slow.sh)]}"
run
expect "an entry over its time cap fails" 1 "^FAST-TIER FAIL stuck .*timed out after 2s"

registry "{\"entries\": [$(entry hung hang-child.sh "[\"$tmp/hung.pids\"]")]}"
started=$SECONDS
run
expect "an entry whose child hangs fails at its cap" 1 "^FAST-TIER FAIL hung .*timed out after 2s"
if [ $((SECONDS - started)) -ge 15 ]; then
  echo "FAIL: a timed-out entry waited on its child's pipe ($((SECONDS - started)) s for two 2 s runs)" >&2
  exit 1
fi
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "FAIL: a timed-out entry left its child $pid running" >&2
    exit 1
  fi
done < "$tmp/hung.pids"

registry '{"entries": [{"name": "orphan", "kind": "script", "path": "bin/pass.sh"}]}'
run
expect "an entry without an owner is refused" 2 "orphan.*owner"

rm -f "$tmp/state"
registry "{\"entries\": [$(entry wobbly flaky.sh "[\"$tmp/state\"]")]}"
run --repeat 3
expect "admission fails an entry whose result changes" 1 "^FAST-TIER NOT-ADMISSIBLE wobbly .*1/3 failed"

registry "{\"entries\": [$(entry ok pass.sh)]}"
run --repeat 3
expect "admission passes a stable entry" 0 "^FAST-TIER ADMISSIBLE ok .*3/3 passed"

registry '{"entries": [
  {"name": "tokens", "kind": "swift", "package": "Packages/Shared/CmuxHomeRender", "filter": "MotionTokenTests", "owner": "op-test"},
  {"name": "intents", "kind": "swift", "package": "Packages/Shared/CmuxHomeRender", "filter": "IntentMappingTests", "owner": "op-test"},
  {"name": "clock", "kind": "cargo", "path": "cmux-tui", "package": "cmux-motion", "owner": "op-test"}]}'
run --dry-run
expect "dry run builds a Swift package once" 0 "^BUILD swift build --build-tests --package-path Packages/Shared/CmuxHomeRender$"
if [ "$(grep -c '^BUILD swift build' <<<"$out")" -ne 1 ]; then echo "FAIL: one build per Swift package" >&2; printf '%s\n' "$out" >&2; exit 1; fi
expect "dry run tests each Swift entry against the built package" 0 "^RUN tokens: swift test --skip-build --package-path Packages/Shared/CmuxHomeRender --filter MotionTokenTests$"
expect "dry run builds cargo test binaries once, outside the cap" 0 "^BUILD cargo test --locked --no-run -p cmux-motion \\(in cmux-tui\\)$"
expect "dry run tests a cargo entry" 0 "^RUN clock: cargo test --locked -p cmux-motion \(in cmux-tui\)$"

# --kind splits one registry between the Linux cargo job and the Mac Swift job:
# each runs and builds only its kinds, and a kind with no entry is refused.
run --dry-run --kind cargo
expect "--kind cargo runs the cargo entry" 0 "^RUN clock: cargo test --locked -p cmux-motion"
if grep -q "swift" <<<"$out"; then echo "FAIL: --kind cargo built or ran a Swift entry" >&2; printf '%s\n' "$out" >&2; exit 1; fi
run --dry-run --kind swift --kind script
expect "--kind swift runs the Swift entries" 0 "^RUN tokens: swift test"
if grep -q "cargo" <<<"$out"; then echo "FAIL: --kind swift built or ran a cargo entry" >&2; printf '%s\n' "$out" >&2; exit 1; fi
run --dry-run --kind script
expect "a --kind with no entry is a bad registry, not an empty pass" 2 "no entry of kind script"
registry "{\"entries\": [$(entry ok pass.sh), {\"name\": \"other\", \"kind\": \"cargo\", \"path\": \"crate\", \"package\": \"core\", \"owner\": \"op-test\"}]}"
run --kind script --receipt "$tmp/kind-receipt.json"
expect "--kind script leaves the cargo entry to its own job" 0 "^FAST-TIER PASS ok "
python3 -I - "$tmp/kind-receipt.json" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
assert receipt["kinds"] == ["script"], receipt
assert [e["name"] for e in receipt["entries"]] == ["ok"], receipt
assert receipt["builds"] == [], receipt
PY

# A filter that matches no test is a failure, never a vacuous pass: a renamed
# test must not silently leave the tier. A fake cargo and swift on PATH print
# what the real ones print for an empty match.
mkdir -p "$tmp/fakebin" "$tmp/root/crate"
cat > "$tmp/fakebin/cargo" <<'EOF2'
#!/usr/bin/env bash
case " $* " in *" --no-run "*) exit 0 ;; esac
case " $* " in *" -- matches "*) echo "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 9 filtered out; finished in 0.01s" ;;
  *) echo "test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 11 filtered out; finished in 0.00s" ;; esac
EOF2
cat > "$tmp/fakebin/swift" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = build ] && exit 0
case " $* " in *" --filter Matches "*) echo "Test run with 3 tests in 1 suite passed after 0.010 seconds." ;;
  *) echo "warning: No matching test cases were run"; echo "Test run with 0 tests in 0 suites passed after 0.001 seconds." ;; esac
EOF2
chmod +x "$tmp/fakebin/cargo" "$tmp/fakebin/swift"
registry '{"entries": [
  {"name": "core hit", "kind": "cargo", "path": "crate", "package": "core", "filter": "matches", "owner": "op-test"},
  {"name": "swift hit", "kind": "swift", "package": "Pkg", "filter": "Matches", "owner": "op-test"}]}'
PATH="$tmp/fakebin:$PATH" run
expect "entries that run tests pass" 0 "^FAST-TIER PASS swift hit "
registry '{"entries": [{"name": "core miss", "kind": "cargo", "path": "crate", "package": "core", "filter": "renamed", "owner": "op-test"}]}'
PATH="$tmp/fakebin:$PATH" run
expect "a cargo filter matching no test fails" 1 "^FAST-TIER FAIL core miss .*matched no test"
registry '{"entries": [{"name": "swift miss", "kind": "swift", "package": "Pkg", "filter": "Renamed", "owner": "op-test"}]}'
PATH="$tmp/fakebin:$PATH" run
expect "a swift filter matching no test fails" 1 "^FAST-TIER FAIL swift miss .*matched no test"

# The Swift package builds and the cargo test build share no outputs, so they
# run side by side: the build phase takes the longer of the two, not the sum.
# Each fake build sleeps 3 s; one after the other would take at least 6 s.
mkdir -p "$tmp/slowbin"
cat > "$tmp/slowbin/cargo" <<'EOF2'
#!/usr/bin/env bash
case " $* " in *" --no-run "*) echo "cargo build output"; sleep 3; [ -z "${FAKE_CARGO_BUILD_FAILS:-}" ]; exit ;; esac
echo "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 9 filtered out; finished in 0.01s"
EOF2
cat > "$tmp/slowbin/swift" <<'EOF2'
#!/usr/bin/env bash
if [ "$1" = build ]; then echo "swift build output"; sleep 3; exit 0; fi
echo "Test run with 3 tests in 1 suite passed after 0.010 seconds."
EOF2
chmod +x "$tmp/slowbin/cargo" "$tmp/slowbin/swift"
registry '{"entries": [
  {"name": "core hit", "kind": "cargo", "path": "crate", "package": "core", "filter": "matches", "owner": "op-test"},
  {"name": "swift hit", "kind": "swift", "package": "Pkg", "filter": "Matches", "owner": "op-test"}]}'
started=$(date +%s)
PATH="$tmp/slowbin:$PATH" run --receipt "$tmp/receipt.json"
elapsed=$(( $(date +%s) - started ))
expect "concurrent builds still run every entry" 0 "^FAST-TIER PASS swift hit "
expect "a build's output stays in the log, named by its build" 0 "^\[Pkg\] swift build output$"
if [ "$elapsed" -ge 6 ]; then
  echo "FAIL: the Swift and cargo builds ran one after the other (${elapsed}s, want under 6s)" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
python3 -I - "$tmp/receipt.json" <<'PY'
import json, sys
builds = json.load(open(sys.argv[1]))["builds"]
assert [b["name"] for b in builds] == ["Pkg", "crate"], builds
assert all(b["status"] == "pass" and b["seconds"] >= 2.5 for b in builds), builds
PY
FAKE_CARGO_BUILD_FAILS=1 PATH="$tmp/slowbin:$PATH" run
expect "a cargo build failure fails the tier" 1 "^FAST-TIER FAIL build:crate: the tests do not build"
if grep -q "^FAST-TIER PASS" <<<"$out"; then echo "FAIL: entries ran after a failed build" >&2; printf '%s\n' "$out" >&2; exit 1; fi

echo "fast-tier.test: ok"
