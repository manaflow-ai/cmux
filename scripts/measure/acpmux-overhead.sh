#!/usr/bin/env bash
# acpmux overhead against each harness run raw, on a quiet Mac. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/acpmux-overhead.sh --ref SHA \
#     [--arg=n=20] [--arg=harness=claude,codex,opencode] [--arg=before=SHA] \
#     [--arg=claude=2.1.303] [--arg=codex=0.163.0] [--arg=opencode=1.19.3] --timeout 5400
# Builds acpmux at this ref (and at before=SHA, to compare a change), installs Claude Code,
# Codex and OpenCode at pinned versions under the step (npm), and runs
# scripts/cmux-next/acpmux-overhead-bench.py: each harness raw and through acpmux, against a
# local stand-in model that answers at once (no credential, no network model), so a
# difference is acpmux's own cost. Exit 1 when acpmux at this ref adds more than noise to the
# p50 of any metric for any harness: guard_ms= (default 5) plus twice the standard error of
# the raw median (cold starts vary by far more than 5 ms); guard_ms=0 measures only.
# Output: ACPMUX-OVERHEAD lines (the table per acpmux build); files under .build/acpmux-overhead.
#
# bench=daemon: the daemon's own budgets instead (plans/cmux-next/acpmux-audit.md): the release
# build of cmux-tui/crates/acpmux/tests/perf_ops.rs (every op send to reply, token to client,
# idle wakeups, processes per chat; light, STRESS and 72 chats), at this ref and, with before=SHA,
# at that ref on the same worker. No harness CLI, no npm. Output: ACPMUX-PERF lines (and
# ACPMUX-PERF-OPEN, a known over-budget finding), each with its label (before/after); per side an
# ACPMUX-PERF-STATUS line with cargo's exit and result (ok, over-budget, failed), and on a nonzero exit
# the tail of its log (ACPMUX-PERF-LOG). Each side's full cargo output: .build/acpmux-overhead/
# perf-<label>.log. Exit 1 when the build at this ref misses a budget or does not build or run; exit 3
# when the before= side did not build or run (no before rows: not a comparison). A before side that
# ran and missed a budget is a comparison (the number a fix is measured against).
#   cmux-ci run --class isolated --script scripts/measure/acpmux-overhead.sh --ref SHA \
#     --arg=bench=daemon [--arg=before=SHA] --timeout 5400 \
#     [--artifact .build/acpmux-overhead/perf-after.log] [--artifact .build/acpmux-overhead/perf-before.log]
#
# bench=prewarm: a new chat's Enter to its first answer text, cold and after the typing prewarm
# (webviews newChatPrewarm.ts, acpmux `_acpmux/prewarm`), same harnesses, stand-in model and
# acpmux build; each run in a fresh folder. Plus the idle cost of typing in 5 new chats in 5
# folders and sending none (warm sessions left, their RSS). With before=SHA both builds run.
# Output: ACPMUX-OVERHEAD lines (one table per build). Exit 1 when a prewarmed Enter at this ref
# missed the pool or a run failed.
#   cmux-ci run --class exclusive --script scripts/measure/acpmux-overhead.sh --ref SHA \
#     --arg=bench=prewarm [--arg=n=20] [--arg=before=SHA] --timeout 5400
#
# bench=hibernate: an idle chat's hibernation (acpmux hub/idle.rs): n chats per harness on screen,
# one turn each, 135 s idle, then whether their agent processes (host, harness, MCP servers) still
# run and the next prompt's time to its first answer text. With before=SHA both builds run.
#   cmux-ci run --class exclusive --script scripts/measure/acpmux-overhead.sh --ref SHA \
#     --arg=bench=hibernate --arg=harness=claude,codex [--arg=n=4] [--arg=before=SHA] --timeout 5400
set -euo pipefail
n=20
harness="claude,codex,opencode"
before=""
claude_version="2.1.303"
codex_version="0.163.0"
opencode_version="1.19.3"
guard_ms=5
bench=harness
for arg in "$@"; do
  case "$arg" in
    bench=*) bench="${arg#bench=}" ;;
    n=*) n="${arg#n=}" ;;
    harness=*) harness="${arg#harness=}" ;;
    before=*) before="${arg#before=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    codex=*) codex_version="${arg#codex=}" ;;
    opencode=*) opencode_version="${arg#opencode=}" ;;
    guard_ms=*) guard_ms="${arg#guard_ms=}" ;;
    *) echo "acpmux-overhead.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$n" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "acpmux-overhead.sh: n is 1-999" >&2; exit 2; }
[[ "$harness" =~ ^(claude|codex|opencode)(,(claude|codex|opencode)){0,2}$ ]] || { echo "acpmux-overhead.sh: harness=claude,codex,opencode" >&2; exit 2; }
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "acpmux-overhead.sh: before= is a 40-character SHA" >&2; exit 2; }
for v in "$claude_version" "$codex_version" "$opencode_version"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "acpmux-overhead.sh: versions are X.Y.Z" >&2; exit 2; }
done
[[ "$guard_ms" =~ ^[0-9]{1,4}$ ]] || { echo "acpmux-overhead.sh: guard_ms is a number" >&2; exit 2; }
[[ "$bench" =~ ^(harness|daemon|prewarm|hibernate)$ ]] || { echo "acpmux-overhead.sh: bench=harness, daemon, prewarm or hibernate" >&2; exit 2; }
# Every tool this bench always calls, checked before anything runs, so a worker without one says
# which at once instead of failing after a build (cmux20-bench had no npm). Build tools are checked
# where a build happens: cargo for the cmux fallback below, cargo and rustup in build-acpmux.sh when
# no acpmux is cached, so a worker with cached builds is never refused for lacking them.
need_tools() {  # need_tools WHAT TOOL...: exit 2 naming every TOOL not on PATH.
  local what="$1" tool missing=()
  shift
  for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  (( ${#missing[@]} == 0 )) && return 0
  echo "ACPMUX-OVERHEAD-MISSING-TOOL ${missing[*]}: $what needs $* on PATH; run the step on a worker that has them" >&2
  exit 2
}
if [[ "$bench" == daemon ]]; then
  need_tools "bench=daemon" git sysctl sw_vers cargo
elif [[ "$bench" == hibernate ]]; then
  # Hibernation counts the agent's processes with ps (acpmux-overhead-bench.py).
  need_tools "bench=hibernate" git sysctl sw_vers curl shasum awk python3 npm ps
else
  need_tools "bench=$bench" git sysctl sw_vers curl shasum awk python3 npm
fi
root="$(git rev-parse --show-toplevel)"
cd "$root"
# Where before= is fetched from: a cmux-ci step tree has no `origin` remote, so origin's URL when
# there is one, else the repository's own URL.
fetch_url="${ACPMUX_OVERHEAD_FETCH_URL:-$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)}"
work="$root/.build/acpmux-overhead"
rm -rf "$work"
mkdir -p "$work/bin" "$work/tools"
if [[ "$bench" == daemon ]]; then
  echo "ACPMUX-PERF-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""
  export CI=1
  # The release daemon, as the app bundles it: the dev profile builds acpmux at opt-level 0.
  # perf LABEL TREE: cargo's whole output goes to perf-LABEL.log; the step log gets every ACPMUX-PERF*
  # row with the label, the budget assertion, one ACPMUX-PERF-STATUS line and, on a nonzero exit, the
  # log's tail. Returns 0 (ok), 1 (ran and missed a budget: the bench's assertion) or 2 (did not build or run).
  perf() {
    local label="$1" tree="$2" log="$work/perf-$1.log" code=0 result=ok
    (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$work/target-$label" cargo test --release --locked \
      -p acpmux --test perf_ops -- --nocapture 2>&1) | tee "$log" \
      | sed -n "s/^\(ACPMUX-PERF[A-Z-]*\) /\1 $label /p;/^over the daemon budgets: \[/,/^]/p" || code=$?
    if (( code != 0 )); then
      # perf_ops asserts its budgets last: the panic payload `over the daemon budgets: [...]` starts a line
      # (after `panicked at ...:`) and libtest ends with `test result: FAILED`. Any other failure means the side
      # has no complete rows (no test target, a lock or compile error, a daemon that did not start). A rustc
      # error that quotes the assert line (`634 |     assert!(..., "over the daemon budgets: ...`) is one.
      if grep -q '^over the daemon budgets: \[' "$log" && grep -q '^test result: FAILED' "$log"; then
        result=over-budget
      else
        result=failed
      fi
    fi
    echo "ACPMUX-PERF-STATUS $label exit=$code result=$result log=$log"
    (( code == 0 )) || tail -n 40 "$log" | sed "s/^/ACPMUX-PERF-LOG $label /"
    case "$result" in ok) return 0 ;; over-budget) return 1 ;; *) return 2 ;; esac
  }
  before_rc=0
  if [[ -n "$before" ]]; then
    depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    git fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$before"
    git worktree add -q --detach "$work/before-src" "$before"
    trap 'git -C "$root" worktree remove --force "$work/before-src" 2>/dev/null || true' EXIT
    perf before "$work/before-src" || before_rc=$?
  fi
  status=0
  perf after "$root" || status=1
  echo "ACPMUX-PERF-LOAD end $(sysctl -n vm.loadavg)"
  if (( status == 0 && before_rc == 2 )); then
    echo "ACPMUX-PERF-INCOMPLETE before=$before did not build or run (ACPMUX-PERF-LOG before): no comparison" >&2
    status=3
  fi
  exit "$status"
fi
echo "ACPMUX-OVERHEAD-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""

# The build scripts run Cargo only on a build host; this step is one.
export CI=1
git submodule update --init --depth 1 ghostty-next
# acpmux gives every chat cmux's own tools (`cmux mcp serve`, found next to its executable), so
# each acpmux build gets the cmux binary of this ref beside it: the published cmux-tui tree,
# else built here.
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
mkdir -p "$work/after" "$work/before"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/cmux"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/cmux" | awk '{print $1}')" == "$sum" ]] || { echo "ACPMUX-OVERHEAD cmux sha256 mismatch ($key)" >&2; exit 1; }
else
  need_tools "the cmux build (no published cmux-tui tree for $key)" cargo
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/cmux"
fi
chmod 755 "$work/cmux"
cp "$work/cmux" "$work/after/cmux"
cp "$work/cmux" "$work/before/cmux"
scripts/cmux-next/build-acpmux.sh --output "$work/after/acpmux"
if [[ -n "$before" ]]; then
  # --depth only in an already-shallow checkout; it would make a full clone shallow.
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$before"
  git worktree add -q --detach "$work/before-src" "$before"
  trap 'git -C "$root" worktree remove --force "$work/before-src" 2>/dev/null || true' EXIT
  (cd "$work/before-src" && git submodule update --init --depth 1 ghostty-next && scripts/cmux-next/build-acpmux.sh --output "$work/before/acpmux")
fi

# The harnesses at pinned versions, under the step only.
npm install --prefix "$work/tools" --no-fund --no-audit \
  "@anthropic-ai/claude-code@$claude_version" "@openai/codex@$codex_version" "opencode-ai@$opencode_version" >/dev/null
export PATH="$work/tools/node_modules/.bin:$PATH"
echo "ACPMUX-OVERHEAD-BIN claude $(claude --version) codex $(codex --version) opencode $(opencode --version)"

status=0
mode=overhead
[[ "$bench" == prewarm ]] && mode=prewarm
[[ "$bench" == hibernate ]] && mode=hibernate
run() {
  local label="$1" bin="$2"
  python3 -I scripts/cmux-next/acpmux-overhead-bench.py --acpmux "$bin" --harness "$harness" -n "$n" --mode "$mode" \
    --label "$label" --json "$work/$label.json" --md "$work/table.md" 2> "$work/$label.log" | sed "s/^/ACPMUX-OVERHEAD /"
}
if [[ "$bench" == hibernate ]]; then
  [[ -n "$before" ]] && run before "$work/before/acpmux"
  run after "$work/after/acpmux"
  tail -n 20 "$work/after.log" | sed "s/^/ACPMUX-OVERHEAD-LOG /"
  exit 0
fi
if [[ "$bench" == prewarm ]]; then
  [[ -n "$before" ]] && run before "$work/before/acpmux"
  run after "$work/after/acpmux"
  tail -n 20 "$work/after.log" | sed "s/^/ACPMUX-OVERHEAD-LOG /"
  echo "ACPMUX-OVERHEAD-LOAD end $(sysctl -n vm.loadavg)"
  python3 -I - "$work/after.json" <<'PY' || status=1
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for h, s in d.items():
    if h.startswith("_"):
        continue
    if s["errors"]:
        bad.append(f"{h}: {len(s['errors'])} failed runs, first: {s['errors'][0]}")
    hits = [r.get("pool_hit", 0) for r in s["runs"]["prewarmed"]]
    print(f"ACPMUX-PREWARM-HITS {h} {sum(hits)}/{len(hits)}")
    if not hits or sum(hits) < len(hits):
        bad.append(f"{h}: a prewarmed Enter missed the pool ({sum(hits)}/{len(hits)})")
for b in bad:
    print("ACPMUX-PREWARM-FAIL " + b)
sys.exit(1 if bad else 0)
PY
  exit "$status"
fi
[[ -n "$before" ]] && run before "$work/before/acpmux"
run after "$work/after/acpmux"
[[ -n "$before" ]] && run before-again "$work/before/acpmux"
echo "ACPMUX-OVERHEAD-LOAD end $(sysctl -n vm.loadavg)"
python3 -I - "$work/after.json" "$guard_ms" <<'PY' || status=1
import json, statistics, sys
d, guard = json.load(open(sys.argv[1])), float(sys.argv[2])
bad = []
for h, s in d.items():
    if h.startswith("_"):
        continue
    if s["errors"]:
        bad.append(f"{h}: {len(s['errors'])} failed runs, first: {s['errors'][0]}")
    for m in ("ready", "first", "end", "warm_first", "warm_end", "requests", "request_kb"):
        delta = s["delta_p50"][m]
        raw = sorted(r[m] for r in s["runs"]["raw"])
        # Noise: the standard error of the raw median (1.25 IQR / sqrt n), so a cold start
        # that varies by hundreds of ms is judged against its own spread, never under guard.
        iqr = raw[(3 * len(raw)) // 4] - raw[len(raw) // 4] if len(raw) >= 4 else 0.0
        limit = guard + 2 * 1.25 * iqr / max(1, len(raw)) ** 0.5
        print(f"ACPMUX-OVERHEAD-DELTA {h} {m} {delta} ms (limit {limit:.1f} ms)")
        if guard and (delta is None or delta > limit):
            bad.append(f"{h} {m}: acpmux adds {delta} ms at p50 (limit {limit:.1f} ms)")
for b in bad:
    print("ACPMUX-OVERHEAD-FAIL " + b)
sys.exit(1 if bad else 0)
PY
exit "$status"
