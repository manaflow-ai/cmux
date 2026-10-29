#!/usr/bin/env bash
# scripts/measure/acpmux-overhead.sh bench=agents: each side's row carries its label, the before=
# side runs this ref's bench (copied over a ref that has none) and only measures, this ref holds the 2048 KB budget,
# and a before= side that did not run is not a comparison. Runs the script in a scratch git repo with a stub cargo
# (no Rust build), so it is safe anywhere.
# Run: bash scripts/measure/tests/acpmux-overhead-agents.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GIT=$(command -v git)
mkdir -p "$TMP/bin" "$TMP/repo/scripts/measure" "$TMP/repo/cmux-tui/crates/acpmux/tests"
cp "$ROOT/scripts/measure/acpmux-overhead.sh" "$TMP/repo/scripts/measure/"
echo '[workspace]' > "$TMP/repo/cmux-tui/Cargo.toml"
echo '# the base fake agent' > "$TMP/repo/cmux-tui/crates/acpmux/tests/fake_agent.py"
for tool in scutil sw_vers; do printf '#!/bin/bash\necho stub\n' > "$TMP/bin/$tool"; done
# shellcheck disable=SC2016 # the stub reads its own $2
printf '#!/bin/bash\ncase "$2" in hw.ncpu) echo 8 ;; *) echo stub ;; esac\n' > "$TMP/bin/sysctl"
# The stub cargo: STUB_BEFORE / STUB_AFTER pick what each side does (ok, over: over its budget, broken: no build).
# It fails like the bench when the tree has no daemon_agent_memory.rs, and its row names the bench's knobs.
cat > "$TMP/bin/cargo" <<'STUB'
#!/bin/bash
case "$PWD" in */before-src/*) side=before; mode="${STUB_BEFORE:-ok}" ;; *) side=after; mode="${STUB_AFTER:-ok}" ;; esac
echo "   Compiling acpmux v0.1.0 ($side)"
if [[ "$mode" == broken || ! -f crates/acpmux/tests/daemon_agent_memory.rs ]]; then
  echo "error: no test target named \`daemon_agent_memory\` in \`acpmux\` package" >&2
  exit 101
fi
echo "ACPMUX-AGENTS {\"agents\":$ACPMUX_AGENTS_BENCH_N,\"bytes\":$ACPMUX_AGENTS_BENCH_BYTES,\"budget_kb\":$ACPMUX_AGENTS_BUDGET_KB,\"per_agent_kb\":1700}"
if [[ "$mode" == over ]]; then
  echo "test result: FAILED. 0 passed; 1 failed" >&2
  exit 101
fi
echo "test result: ok. 1 passed; 0 failed" >&2
STUB
chmod +x "$TMP/bin/"*
(cd "$TMP/repo" && "$GIT" init -q && "$GIT" add -A && "$GIT" -c user.name=t -c user.email=t@t commit -qm base \
  && "$GIT" remote add origin "$TMP/repo")
BEFORE=$("$GIT" -C "$TMP/repo" rev-parse HEAD)
# This ref adds the bench.
echo '// the bench' > "$TMP/repo/cmux-tui/crates/acpmux/tests/daemon_agent_memory.rs"
echo '# the new fake agent' > "$TMP/repo/cmux-tui/crates/acpmux/tests/fake_agent.py"
(cd "$TMP/repo" && "$GIT" add -A && "$GIT" -c user.name=t -c user.email=t@t commit -qm bench)
fail() { echo "FAIL: $*"; exit 1; }
# run ENV... -- ARGS...: the script's output in $out, its exit status in $code.
run() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  code=0
  out=$(cd "$TMP/repo" && env -i PATH="$TMP/bin:$(dirname "$GIT"):/usr/bin:/bin" HOME="$TMP" ${envs[@]+"${envs[@]}"} \
    /bin/bash scripts/measure/acpmux-overhead.sh bench=agents "$@" 2>&1) || code=$?
}

# 1. Both sides run 100 agents by default; the before side runs this ref's bench and measures only.
run -- "before=$BEFORE"
[[ "$code" -eq 0 ]] || fail "a passing comparison exited $code: $out"
grep -q '^ACPMUX-AGENTS before {"agents":100,"bytes":2048,"budget_kb":0,' <<<"$out" || fail "no before row with budget 0: $out"
grep -q '^ACPMUX-AGENTS after {"agents":100,"bytes":2048,"budget_kb":2048,' <<<"$out" || fail "no after row with the budget: $out"
grep -q '^ACPMUX-AGENTS-STATUS after exit=0 result=ok' <<<"$out" || fail "no status for the after side: $out"

# 2. The knobs reach the bench.
run -- n=7 bytes=8192
grep -q '^ACPMUX-AGENTS after {"agents":7,"bytes":8192,' <<<"$out" || fail "n= and bytes= did not reach the bench: $out"

# 3. This ref over its budget fails the run.
run STUB_AFTER=over --
[[ "$code" -eq 1 ]] || fail "an after side over budget exited $code: $out"
grep -q '^ACPMUX-AGENTS-STATUS after exit=101 result=over-budget' <<<"$out" || fail "not result=over-budget: $out"

# 4. A before side that did not build is no comparison: exit 3.
run STUB_BEFORE=broken -- "before=$BEFORE"
[[ "$code" -eq 3 ]] || fail "a before side that did not build exited $code: $out"
grep -q '^ACPMUX-AGENTS-STATUS before exit=101 result=failed' <<<"$out" || fail "the before side is not result=failed: $out"

# 5. Bad knobs are refused before anything runs.
run -- chunks=0
[[ "$code" -eq 2 ]] || fail "chunks=0 exited $code: $out"

echo "PASS acpmux-overhead-agents"
