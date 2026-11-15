#!/usr/bin/env bash
# The god chat against the small one, before and after a change, from one harness on one machine: the perf cron's two
# transcript-replay runs (web-ui-suite.ts `transcript-replay`, `--turns 600`, and `transcript-replay-god`, FIXTURE=god)
# at this checkout's pane and at BASE's pane (a detached worktree of BASE with this checkout's bench and node_modules,
# removed when done), interleaved ROUNDS times, so a busy runner slows both sides alike. Prints, per side, the median
# over rounds of each row's p95 and the god / small ratio the cron's god_ratio_rows makes of them (perf-cron.py: god
# p95 / small p95; Leo, 2026-11-12: a god chat shows "no perceivable difference", within 1.2x). Each run's log goes
# to OUT (default $FAST_CHECKS_OUT). The checkout itself is never touched. BASE `-` measures this checkout only.
#   bench/god-ratio-ab.sh BASE [rounds=3]
#   cmux-ci test --setup playwright -- bash webviews/bench/god-ratio-ab.sh <base sha> 3
set -euo pipefail
base="${1:?usage: god-ratio-ab.sh BASE [rounds]}"
rounds="${2:-3}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
sides=(after)
if [ "$base" != - ]; then
  # A fetch here never turns a full clone shallow: --depth only when the checkout already is one.
  depth=()
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
  base="$(git rev-parse --verify -q "$base^{commit}" || { git fetch -q "${depth[@]}" origin "$base" && git rev-parse "$base^{commit}"; })"
  tree="$(mktemp -d)/base"
  trap 'git -C "$here" worktree remove --force "$tree" 2>/dev/null || true' EXIT
  git worktree add -q --detach "$tree" "$base"
  rel="$(git rev-parse --show-prefix)"
  rm -rf "$tree/$rel/bench"
  cp -R "$here/bench" "$tree/$rel/bench"
  ln -s "$here/node_modules" "$tree/$rel/node_modules"
  # The base's generated strings (gitignored, made by `bun install`'s postinstall), from its own sources.
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  sides+=(before)
fi
dir_of() { if [ "$1" = after ]; then echo "$here"; else echo "$tree/$rel"; fi; }
# `run SIDE SCALE ROUND`: the cron's run of SCALE at SIDE's pane; its output to OUT/SIDE-SCALE-ROUND.log.
run() {
  local side="$1" scale="$2" round="$3" log="$out/$1-$2-$3.log"
  echo "=== $side $scale round $round"
  if [ "$scale" = god ]; then
    (cd "$(dir_of "$side")" && FIXTURE=god timeout 600 bun bench/transcript-replay.bench.ts) >"$log" 2>&1 || echo "=== $side $scale FAILED"
  else
    (cd "$(dir_of "$side")" && timeout 600 bun bench/transcript-replay.bench.ts --turns 600 --only long) >"$log" 2>&1 ||
      echo "=== $side $scale FAILED"
  fi
  grep -E '^  (token|thought|tool_call|tool_output) at |heap \+|BUDGET MISS' "$log" || true
}
for round in $(seq 1 "$rounds"); do
  for side in "${sides[@]}"; do
    run "$side" small "$round"
    run "$side" god "$round"
  done
done
python3 - "$out" "$rounds" "${sides[@]}" <<'PY'
import json, statistics, sys
out, rounds, sides = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
kinds = ["token_ms", "thought_ms", "tool_call_ms", "tool_output_ms", "heap_mb",
         "token_slope_ms_per_krow", "thought_slope_ms_per_krow", "tool_call_slope_ms_per_krow"]
def rows(path):
    found = {}
    try:
        for line in open(path):
            if line.startswith("PERF_ROW "):
                row = json.loads(line[len("PERF_ROW "):])
                found[row["name"]] = row["p95"]
    except OSError:
        pass
    return found
print(f"god-ratio-ab: median over {rounds} rounds of each row's p95 (per round: " + ", ".join(sides) + ")")
print(f"{'row':<28}" + "".join(f"{side + ' ' + col:>18}" for side in sides for col in ("small", "god", "ratio")))
for kind in kinds:
    line = f"{kind:<28}"
    for side in sides:
        small = [rows(f"{out}/{side}-small-{r}.log").get(f"transcript_replay.long.{kind}") for r in range(1, rounds + 1)]
        god = [rows(f"{out}/{side}-god-{r}.log").get(f"transcript_replay.god.long.{kind}") for r in range(1, rounds + 1)]
        small = [v for v in small if v is not None]
        god = [v for v in god if v is not None]
        s = statistics.median(small) if small else None
        g = statistics.median(god) if god else None
        ratio = round(g / s, 3) if s and g and "slope" not in kind else None
        line += "".join(f"{('-' if v is None else v):>18}" for v in (s, g, ratio))
        line += ""
    print(line)
    for side in sides:
        each = [(rows(f"{out}/{side}-small-{r}.log").get(f"transcript_replay.long.{kind}"),
                 rows(f"{out}/{side}-god-{r}.log").get(f"transcript_replay.god.long.{kind}")) for r in range(1, rounds + 1)]
        print(f"    {side} rounds (small, god): {each}")
PY
echo "god-ratio-ab: wrote $out"
