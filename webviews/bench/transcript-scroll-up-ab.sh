#!/usr/bin/env bash
# Scrolling up a long chat, before and after a change, from one harness on one machine: bench/transcript-scroll-up
# (FIXTURE=flat ROWS=100000 PAGES=24 ENGINES=chromium, MODE fling unless set) at this checkout's pane and at each
# SHA's pane (a detached worktree with this checkout's bench and node_modules, removed when done), interleaved
# REPEATS times. Leo, 2026-11-16: "how about speeding up the scrolling up of chats?"
#   bench/transcript-scroll-up-ab.sh BASE [repeats=8] [SHA...]
#   cmux-ci test --setup playwright -- bash webviews/bench/transcript-scroll-up-ab.sh <base sha> 8 <base sha> <sha>
# (on the fleet, name each SHA in full: its snapshot has no origin and fetches them from the public repository)
# Name BASE twice for the base-vs-base floor: `transcript-scroll-up-ab.sh B 8 B S` measures this checkout, B, B
# again and S. BASE `-` measures this checkout only. Every run's environment passes on to the bench (MODE, ROUNDS,
# ROWS, PAGES, LATENCY ...). The order of the sides turns every repeat, so a runner warming or tiring over the run
# lands on every side alike. Per side it prints the median over repeats of each run's older-page ask-to-drawn p50,
# p95 and max, frame p95, blank frames and loading frames, with the median's 95% interval (a seeded bootstrap) and
# min..max; and the p50/p95 of every older page of every repeat, pooled. Each run's log goes to OUT (default
# $FAST_CHECKS_OUT).
set -euo pipefail
base="${1:?usage: transcript-scroll-up-ab.sh BASE [repeats] [SHA...]}"
repeats="${2:-8}"
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
  local name="$1" sha="$2" depth=() tree remote=origin
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
  # A checkout with no origin (a fleet run's snapshot) fetches from the public repository; a SHA not
  # here is fetched by its full id.
  git remote get-url origin >/dev/null 2>&1 || remote=https://github.com/manaflow-ai/cmux.git
  sha="$(git rev-parse --verify -q "$sha^{commit}" || { git fetch -q "${depth[@]}" "$remote" "$sha" && git rev-parse FETCH_HEAD; })"
  tree="$(mktemp -d)/$name"
  trees+=("$tree")
  git worktree add -q --detach "$tree" "$sha"
  rm -rf "$tree/$rel/bench"
  cp -R "$here/bench" "$tree/$rel/bench"
  ln -s "$here/node_modules" "$tree/$rel/node_modules"
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  dirs[$name]="$tree/$rel"
  sides+=("$name")
  echo "=== side $name at $sha"
}
if [ "$base" != - ]; then
  side before "$base"
  for at in "${!extra[@]}"; do side "s$((at + 1))-${extra[$at]:0:10}" "${extra[$at]}"; done
fi
# `run SIDE REPEAT`: one bench run at SIDE's pane; its output to OUT/SIDE-REPEAT.log. A run counts when it ends with
# its verdict and its numbers: exit 0 (PASS) or 1 (MISS, the bench's own budget, which both sides may miss; the
# comparison still has its numbers). Anything else (the 900 s timeout, a failed build, a throw, a run that printed
# no numbers) stops the comparison, naming the side and repeat with the log's end: a missing run must not read as
# a comparison with less data.
run() {
  local side="$1" repeat="$2" log="$out/$1-$2.log" status=0
  echo "=== $side repeat $repeat"
  (cd "${dirs[$side]}" && FIXTURE=flat ROWS="${ROWS:-100000}" MODE="${MODE:-fling}" PAGES="${PAGES:-24}" \
    ENGINES=chromium timeout 900 bun bench/transcript-scroll-up.bench.ts) >"$log" 2>&1 || status=$?
  if { [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; } ||
    ! grep -qE '^transcript-scroll-up chromium verdict: ' "$log" ||
    ! grep -qE '^transcript-scroll-up chromium askToDrawnP95: ' "$log"; then
    local why="exit $status"
    [ "$status" -eq 124 ] && why="the 900 s timeout"
    echo "transcript-scroll-up-ab: $side repeat $repeat broke ($why); the end of $log:" >&2
    tail -n 30 "$log" >&2
    exit 1
  fi
  grep -E '^transcript-scroll-up chromium (askToDrawnP95|frameP95|blankFrames|loadingFrames|undrawnAsks):' "$log" | tr '\n' ' '
  echo
}
n=${#sides[@]}
for repeat in $(seq 1 "$repeats"); do
  for k in $(seq 0 $((n - 1))); do run "${sides[$(((k + repeat - 1) % n))]}" "$repeat"; done
done
python3 - "$out" "$repeats" "${sides[@]}" <<'PY'
import json, random, re, statistics, sys
out, repeats, sides = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
def summary(path):
    found = {}
    try:
        for line in open(path):
            m = re.match(r"transcript-scroll-up chromium (\w+): (.*)$", line)
            if m:
                try:
                    found[m.group(1)] = json.loads(m.group(2))
                except ValueError:
                    pass
    except OSError:
        pass
    return found
def ci(values, draws=4000):
    rng = random.Random(1)
    meds = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(draws))
    return meds[int(draws * 0.025)], meds[int(draws * 0.975)]
def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, max(0, round(p / 100 * (len(s) - 1))))] if s else float("nan")
runs = {s: [summary(f"{out}/{s}-{r}.log") for r in range(1, repeats + 1)] for s in sides}
print(f"transcript-scroll-up-ab: {repeats} repeats; per side the median over repeats, its 95% interval, min..max")
for key in ("askToDrawnP50", "askToDrawnP95", "askToDrawnMax", "frameP95", "blankFrames", "loadingFrames", "undrawnAsks"):
    print(f"{key}:")
    for s in sides:
        values = [run[key] for run in runs[s] if isinstance(run.get(key), (int, float))]
        if not values:
            print(f"  {s:<22} -")
            continue
        lo, hi = ci(values)
        print(f"  {s:<22} {statistics.median(values):9.1f} [{lo:.1f}, {hi:.1f}] (min {min(values):.1f} max "
              f"{max(values):.1f}, n {len(values)})  {[round(v, 1) for v in values]}")
print("every older page of every repeat, pooled (ask to drawn, ms):")
for s in sides:
    pages = []
    for r in range(1, repeats + 1):
        try:
            for line in open(f"{out}/{s}-{r}.log"):
                m = re.match(r"transcript-scroll-up chromium page \S+ askToDrawn ([\d.]+)", line)
                if m:
                    pages.append(float(m.group(1)))
        except OSError:
            pass
    if pages:
        print(f"  {s:<22} p50 {pct(pages, 50):.1f} p95 {pct(pages, 95):.1f} max {max(pages):.1f} (n {len(pages)})")
PY
echo "transcript-scroll-up-ab: wrote $out"
