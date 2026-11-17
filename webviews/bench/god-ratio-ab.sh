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
# What makes one run decide a 0.1x change. Run one after the other, a round's god / small ratio swung 0.5x to 1.9x
# on the same code (8-round A/A, run 43714459962, CPU clock or wall): the shared runner runs at one speed for one
# replay and up to twice as slow for the next, minutes apart. So:
# - each round plays god and small at once (transcript-replay's PAIRED=1): two pages, each burst of the god chat
#   measured right after the same burst of the small one (which goes first turns each burst), seconds apart;
# - the verdict is the median over rounds of each round's ratio, with the 95% interval of that median (a seeded
#   bootstrap) and the spread (min to max); `pairs` is the median over every round's checkpoints of god / small for
#   the same checkpoint, the finest pairing there is;
# - the order of the sides turns every round, so a runner warming or tiring over the run lands on every side alike.
# It prints the per-round ratios of the p95 rows (the worst checkpoint, what the cron reads) and of the p50 rows (the
# median checkpoint). CLOCK=cpu passes on to the bench (CPU time, not wall). Each run's log goes to OUT (default
# $FAST_CHECKS_OUT). The checkout itself is never touched.
set -euo pipefail
base="${1:?usage: god-ratio-ab.sh BASE [rounds] [SHA...]}"
rounds="${2:-8}"
shift 2 2>/dev/null || shift $#
extra=("$@")
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
# `run SIDE ROUND`: the cron's god and small (`--turns 600`) replays at SIDE's pane, played at once; its output to
# OUT/SIDE-ROUND.log.
run() {
  local side="$1" round="$2" log="$out/$1-$2.log"
  echo "=== $side round $round"
  (cd "${dirs[$side]}" && PAIRED=1 timeout 900 bun bench/transcript-replay.bench.ts --turns 600 --only long) >"$log" 2>&1 ||
    echo "=== $side FAILED"
  grep -E '^  (god|long) (token|thought) at |heap \+|BUDGET MISS' "$log" || true
}
n=${#sides[@]}
for round in $(seq 1 "$rounds"); do
  for k in $(seq 0 $((n - 1))); do run "${sides[$(((k + round - 1) % n))]}" "$round"; done
done
python3 - "$out" "$rounds" "${CLOCK:-wall}" "${sides[@]}" <<'PY'
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
logs = {(s, r): rows(f"{out}/{s}-{r}.log") for s in sides for r in range(1, rounds + 1)}
def value(s, scale, r, kind, stat):
    name = f"transcript_replay.{'god.' if scale == 'god' else ''}long.{kind}"
    return logs[(s, r)].get(name, {}).get(stat)
def bursts(s, r, kind):
    """Each checkpoint's (small, god) ms per record for KIND in round R, in order."""
    found = {"god": [], "long": []}
    try:
        for line in open(f"{out}/{s}-{r}.log"):
            parts = line.split()
            if len(parts) > 5 and line.startswith("  ") and parts[0] in found and parts[1] == kind and parts[2] == "at":
                found[parts[0]].append(float(parts[5]))
    except OSError:
        pass
    return list(zip(found["long"], found["god"]))
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
    if kind in ("token_ms", "thought_ms"):
        print(f"{kind} pairs (each checkpoint's god / small, every round):")
        for s in sides:
            each = [g / a for r in range(1, rounds + 1) for a, g in bursts(s, r, kind[:-3]) if a]
            if each:
                lo, hi = ci(each)
                print(f"  {s:<22} ratio {statistics.median(each):.3f} [{lo:.3f}, {hi:.3f}] (n {len(each)})")
PY
echo "god-ratio-ab: wrote $out"
