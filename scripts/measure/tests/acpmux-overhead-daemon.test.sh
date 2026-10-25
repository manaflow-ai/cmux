#!/usr/bin/env bash
# scripts/measure/acpmux-overhead.sh bench=daemon (deep review bench-small, 2026-10-23): every side's cargo
# output is kept, each side's exit shows, and a before= side that did not build or run is not read as a
# comparison. Runs the script in a scratch git repo with a stub cargo (no Rust build), so it is safe anywhere;
# the stub fails the before side the way a ref without tests/perf_ops.rs fails.
# Run: bash scripts/measure/tests/acpmux-overhead-daemon.test.sh
# Run by hand on a Freestyle VM, never in CI and never on a laptop: ~/fun/cmuxterm-hq/scripts/freestyle-run.sh --label acpmux-overhead-test --snapshot node --sync . -- bash scripts/measure/tests/acpmux-overhead-daemon.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GIT=$(command -v git)
mkdir -p "$TMP/bin" "$TMP/repo/scripts/measure" "$TMP/repo/cmux-tui"
cp "$ROOT/scripts/measure/acpmux-overhead.sh" "$TMP/repo/scripts/measure/"
echo '[workspace]' > "$TMP/repo/cmux-tui/Cargo.toml"  # the before worktree needs the directory
for tool in scutil sw_vers; do printf '#!/bin/bash\necho stub\n' > "$TMP/bin/$tool"; done
printf '#!/bin/bash\ncase "$2" in hw.ncpu) echo 8 ;; *) echo stub ;; esac\n' > "$TMP/bin/sysctl"
# The stub cargo: STUB_BEFORE / STUB_AFTER pick what each side does (ok, over: a missed budget, broken: no build,
# compile: perf_ops.rs does not compile, and rustc's error quotes the budget assert's line).
cat > "$TMP/bin/cargo" <<'STUB'
#!/bin/bash
case "$PWD" in */before-src/*) side=before; mode="${STUB_BEFORE:-ok}" ;; *) side=after; mode="${STUB_AFTER:-ok}" ;; esac
echo "   Compiling acpmux v0.1.0 ($side)"
if [[ "$mode" == broken ]]; then
  echo "error: no test target named \`perf_ops\` in \`acpmux\` package" >&2
  exit 101
fi
if [[ "$mode" == compile ]]; then
  cat >&2 <<'RUSTC'
error[E0609]: no field `over` on type `Report`
   --> crates/acpmux/tests/perf_ops.rs:634:20
    |
634 |     assert!(report.over.is_empty(), "over the daemon budgets: {:#?}", report.over);
    |                    ^^^^ unknown field
error: could not compile `acpmux` (test "perf_ops") due to 1 previous error
RUSTC
  exit 101
fi
echo "ACPMUX-PERF light._acpmux/status p50_ms=0.10 p95_ms=0.20 max_ms=0.30 n=100" >&2
echo "ACPMUX-PERF-OPEN stress._acpmux/attach p95_ms=3.10 > 2 (finding 7)" >&2
if [[ "$mode" == over ]]; then
  echo "thread 'acpmux_ops_and_streaming' panicked at tests/perf_ops.rs:634:5:" >&2
  printf 'over the daemon budgets: [\n    "light._acpmux/rename p95_ms=4.0 > 2",\n]\n' >&2
  echo "test result: FAILED. 0 passed; 1 failed" >&2
  exit 101
fi
echo "test result: ok. 1 passed; 0 failed" >&2
STUB
chmod +x "$TMP/bin/"*
(cd "$TMP/repo" && "$GIT" init -q && "$GIT" add -A && "$GIT" -c user.name=t -c user.email=t@t commit -qm base \
  && "$GIT" remote add origin "$TMP/repo")
BEFORE=$("$GIT" -C "$TMP/repo" rev-parse HEAD)
fail() { echo "FAIL: $*"; exit 1; }
# run ENV... -- ARGS...: the script's output in $out, its exit status in $code.
run() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  code=0
  out=$(cd "$TMP/repo" && env -i PATH="$TMP/bin:$(dirname "$GIT"):/usr/bin:/bin" HOME="$TMP" ${envs[@]+"${envs[@]}"} \
    /bin/bash scripts/measure/acpmux-overhead.sh bench=daemon "$@" 2>&1) || code=$?
}
WORK="$TMP/repo/.build/acpmux-overhead"

# 1. The before side does not build: its error and exit show, and the run is not a passing comparison.
run STUB_BEFORE=broken -- "before=$BEFORE"
[[ "$code" -ne 0 ]] || fail "a before side that did not build passed (exit 0): $out"
grep -q '^ACPMUX-PERF-STATUS before exit=101' <<<"$out" || fail "no exit status for the before side: $out"
grep -q "no test target named .perf_ops." <<<"$out" || fail "the before side's error is not in the step log: $out"
grep -q '^ACPMUX-PERF after light\._acpmux/status ' <<<"$out" || fail "the after rows are missing: $out"
grep -q 'Compiling acpmux v0.1.0 (before)' "$WORK/perf-before.log" || fail "no full cargo log for the before side"
grep -q 'Compiling acpmux v0.1.0 (after)' "$WORK/perf-after.log" || fail "no full cargo log for the after side"

# 2. Known over-budget rows (ACPMUX-PERF-OPEN) keep their line and get the side's label.
grep -q '^ACPMUX-PERF-OPEN after stress\._acpmux/attach ' <<<"$out" || fail "the ACPMUX-PERF-OPEN row was dropped: $out"
grep -q '^ACPMUX-PERF-STATUS after exit=0' <<<"$out" || fail "no exit status for the after side: $out"

# 3. A before side that ran and missed a budget is a comparison (what a fix is measured against): exit 0.
run STUB_BEFORE=over -- "before=$BEFORE"
[[ "$code" -eq 0 ]] || fail "a before side over its budgets failed the run (exit $code): $out"
grep -q '^ACPMUX-PERF before light\._acpmux/status ' <<<"$out" || fail "the before rows are missing: $out"
grep -q '^ACPMUX-PERF-STATUS before exit=101' <<<"$out" || fail "no exit status for the over-budget before side: $out"

# 4. The after side that does not build fails the run and says why.
run STUB_AFTER=broken --
[[ "$code" -eq 1 ]] || fail "an after side that did not build exited $code: $out"
grep -q '^ACPMUX-PERF-STATUS after exit=101' <<<"$out" || fail "no exit status for the broken after side: $out"
grep -q "no test target named .perf_ops." <<<"$out" || fail "the after side's error is not in the step log: $out"

# 5. A before side whose perf_ops.rs does not compile is a side that did not build, even though rustc's error
#    quotes the budget assert's text: exit 3 (no comparison), and the compile log stays behind its label.
run STUB_BEFORE=compile -- "before=$BEFORE"
[[ "$code" -eq 3 ]] || fail "a before side that did not compile exited $code (read as over its budgets): $out"
grep -q '^ACPMUX-PERF-STATUS before exit=101 result=failed' <<<"$out" || fail "the before side is not result=failed: $out"
grep -q '^634 |' <<<"$out" && fail "the compile error spilled into the step log without its label: $out"
grep -q '^ACPMUX-PERF-LOG before error\[E0609\]' <<<"$out" || fail "the before side's compile error is not in its log tail: $out"

echo "PASS acpmux-overhead-daemon"
