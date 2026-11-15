#!/usr/bin/env bash
# The god chat against the small one, before and after a change, from one harness on one machine: the perf cron's two
# transcript-replay runs (web-ui-suite.ts `transcript-replay`, `--turns 600`, and `transcript-replay-god`, FIXTURE=god)
# at this checkout's pane and at BASE's pane (a detached worktree of BASE with this checkout's bench and node_modules,
# removed when done), interleaved ROUNDS times. Leo, 2026-11-12: a god chat shows "no perceivable difference", within
# 1.2x (perf-cron.py god_ratio_rows: god p95 / small p95).
#   bench/god-ratio-ab.sh BASE [rounds=8] [SHA...]
#   cmux-ci test --setup playwright -- bash webviews/bench/god-ratio-ab.sh <full base sha> 8
# Each extra SHA is one more side, in a worktree of its own like BASE's: `god-ratio-ab.sh B 8 B` is an A/A run (the
# same code twice), `god-ratio-ab.sh B 8 S1 S2` measures each commit of a stack beside the checkout. BASE `-` measures
# this checkout only.
# What makes one run decide a 0.1x change (a single round's ratio swung 1.1x to 1.7x on the same code):
# - every round runs each side's small and god replay back to back and divides them there, so a ratio never pairs a
#   slow minute of the runner with a quiet one; the verdict is the median over rounds of those per-round ratios, with
#   the 95% interval of that median (a seeded bootstrap) and the spread (min to max);
# - the order of the sides, and of small and god inside each, turns every round, so a runner warming or tiring over
#   the run lands on every side alike;
# - CLOCK=cpu (the default here, CLOCK=wall for the cron's own) counts the renderer main thread's CPU time, not its
#   tasks' wall time, which also counts the time a task waits on a busy shared runner.
# It prints both per-round ratios: of the p95 rows (the worst checkpoint, what the cron reads) and of the p50 rows
# (the median checkpoint). Each run's log goes to OUT (default $FAST_CHECKS_OUT). The checkout itself is never touched.
set -euo pipefail
base="${1:?usage: god-ratio-ab.sh BASE [rounds] [SHA...]}"
rounds="${2:-8}"
shift 2 2>/dev/null || shift $#
extra=("$@")
export CLOCK="${CLOCK:-cpu}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
rel="$(git rev-parse --show-prefix)"
sides=(after)
declare -A dirs=([after]="$here")
trees=()
trap 'for t in "${trees[@]}"; do git -C "$here" worktree remove --force "$t" 2>/dev/null || true; done' EXIT
# `side NAME SHA`: a detached worktree of SHA with this checkout's bench and node_modules, measured as side NAME.
side() {
  local name="$1" sha="$2" depth=() tree
  # A fetch here never turns a full clone shallow: --depth only when the checkout already is one.
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
  sha="$(git rev-parse --verify -q "$sha^{commit}" || { git fetch -q "${depth[@]}" origin "$sha" && git rev-parse "$sha^{commit}"; })"
  tree="$(mktemp -d)/$name"
  trees+=("$tree")
  git worktree add -q --detach "$tree" "$sha"
  rm -rf "$tree/$rel/bench"
  cp -R "$here/bench" "$tree/$rel/bench"
  ln -s "$here/node_modules" "$tree/$rel/node_modules"
  # The side's generated strings (gitignored, made by `bun install`'s postinstall), from its own sources.
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  dirs[$name]="$tree/$rel"
  sides+=("$name")
  echo "=== side $name at $sha"
}
if [ "$base" != - ]; then
  side before "$base"
  for at in "${!extra[@]}"; do side "s$((at + 1))-${extra[$at]:0:10}" "${extra[$at]}"; done
fi
# `run SIDE SCALE ROUND`: the cron's run of SCALE at SIDE's pane; its output to OUT/SIDE-SCALE-ROUND.log.
run() {
  local side="$1" scale="$2" round="$3" log="$out/$1-$2-$3.log"
  echo "=== $side $scale round $round"
  if [ "$scale" = god ]; then
    (cd "${dirs[$side]}" && FIXTURE=god timeout 600 bun bench/transcript-replay.bench.ts) >"$log" 2>&1 || echo "=== $side $scale FAILED"
  else
    (cd "${dirs[$side]}" && timeout 600 bun bench/transcript-replay.bench.ts --turns 600 --only long) >"$log" 2>&1 ||
      echo "=== $side $scale FAILED"
  fi
  grep -E '^  (token|thought) at |heap \+|BUDGET MISS' "$log" || true
}
n=${#sides[@]}
for round in $(seq 1 "$rounds"); do
  for k in $(seq 0 $((n - 1))); do
    s="${sides[$(((k + round - 1) % n))]}"
    if [ $((round % 2)) = 1 ]; then run "$s" small "$round"; run "$s" god "$round"; else run "$s" god "$round"; run "$s" small "$round"; fi
  done
done
python3 - "$out" "$rounds" "$CLOCK" "${sides[@]}" <<'PY'
import json, random, statistics, sys
out, rounds, clock, sides = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
def rows(path):
    found = {}
    try:
        for line in open(path):
            if line.startswith("PERF_ROW "):
                row = json.loads(line[len("PERF_ROW "):])
                found[row["name"]] = row
    except OSError:
        pass
    return found
def ci(values, draws=4000):
    """The median's 95% interval: a seeded bootstrap over the rounds."""
    rng = random.Random(1)
    meds = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(draws))
    return meds[int(draws * 0.025)], meds[int(draws * 0.975)]
logs = {(s, scale, r): rows(f"{out}/{s}-{scale}-{r}.log") for s in sides for scale in ("small", "god") for r in range(1, rounds + 1)}
def value(s, scale, r, kind, stat):
    name = f"transcript_replay.{'god.' if scale == 'god' else ''}long.{kind}"
    return logs[(s, scale, r)].get(name, {}).get(stat)
print(f"god-ratio-ab: {rounds} rounds, CLOCK={clock}; per side the median over rounds of each round's god / small "
      "ratio, its 95% interval and min..max; then the medians of small and god themselves")
for kind, stats in (("token_ms", ("p95", "p50")), ("thought_ms", ("p95", "p50")), ("tool_call_ms", ("p95",)),
                    ("tool_output_ms", ("p95",)), ("heap_mb", ("p95",))):
    for stat in stats:
        print(f"{kind} {stat}:")
        for s in sides:
            pairs = [(value(s, "small", r, kind, stat), value(s, "god", r, kind, stat)) for r in range(1, rounds + 1)]
            pairs = [(a, b) for a, b in pairs if a and b is not None]
            if not pairs:
                print(f"  {s:<22} -")
                continue
            ratios = [b / a for a, b in pairs]
            med = statistics.median(ratios)
            lo, hi = ci(ratios)
            print(f"  {s:<22} ratio {med:.3f} [{lo:.3f}, {hi:.3f}] (min {min(ratios):.3f} max {max(ratios):.3f}, "
                  f"n {len(ratios)})  small {statistics.median(a for a, _ in pairs):.3f} god "
                  f"{statistics.median(b for _, b in pairs):.3f}  rounds {[round(x, 3) for x in ratios]}")
PY
echo "god-ratio-ab: wrote $out"
