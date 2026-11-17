#!/usr/bin/env bash
# A released chat the prewarmed spare page takes (first-load-after-restart MODE=reopen-spare), before and after a
# change, from one harness on one machine: this checkout's pane and BASE's pane (a detached worktree of BASE with this
# checkout's bench and node_modules, removed when done), interleaved ROUNDS times at each TURNS.
#   bench/reopen-spare-ab.sh BASE [rounds=3] [turns=10,100]
#   cmux-ci test --setup playwright -- bash webviews/bench/reopen-spare-ab.sh <full base sha> 3 10,100
# PROFILE=1 passes on (the adopt's CPU profile per side); ROUNDS_EACH (default 5) is the bench's own ROUNDS per run.
# Per side and TURNS it prints each run's summary lines (first content, live, adopt task, spare footprint) and the
# median over runs of first content p50 and of the adopt task p50. Each run's log goes to OUT (default
# $FAST_CHECKS_OUT). The checkout itself is never touched.
set -euo pipefail
base="${1:?usage: reopen-spare-ab.sh BASE [rounds] [turns]}"
rounds="${2:-3}"
IFS=, read -r -a turns <<<"${3:-10,100}"
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
if [ "$base" != - ]; then
  depth=()
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
  sha="$(git rev-parse --verify -q "$base^{commit}" || { git fetch -q "${depth[@]}" origin "$base" && git rev-parse "$base^{commit}"; })"
  tree="$(mktemp -d)/before"
  trees+=("$tree")
  git worktree add -q --detach "$tree" "$sha"
  rm -rf "$tree/$rel/bench"
  cp -R "$here/bench" "$tree/$rel/bench"
  ln -s "$here/node_modules" "$tree/$rel/node_modules"
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  dirs[before]="$tree/$rel"
  sides+=(before)
  echo "=== side before at $sha"
fi
run() {
  local side="$1" turn="$2" round="$3" log="$out/$1-t$2-$3.log"
  echo "=== $side TURNS=$turn round $round"
  (cd "${dirs[$side]}" && MODE=reopen-spare TURNS="$turn" ROUNDS="${ROUNDS_EACH:-5}" timeout 1200 \
    bun bench/first-load-after-restart.bench.ts) >"$log" 2>&1 || echo "=== $side FAILED (exit $?)"
  grep -E '^reopen-spare' "$log" | grep -v 'profile' || true
  if [ "${PROFILE:-}" = 1 ]; then sed -n '/^reopen-spare adopt profile/,$p' "$log" | head -110; fi
}
n=${#sides[@]}
for turn in "${turns[@]}"; do
  for round in $(seq 1 "$rounds"); do
    for k in $(seq 0 $((n - 1))); do run "${sides[$(((k + round - 1) % n))]}" "$turn" "$round"; done
  done
done
python3 -I - "$out" "$rounds" "${turns[*]}" "${sides[@]}" <<'PY'
import re, statistics, sys
out, rounds, turns, sides = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(), sys.argv[4:]
def grab(path, pattern):
    try:
        for line in open(path):
            m = re.search(pattern, line)
            if m:
                return float(m.group(1))
    except OSError:
        pass
    return None
print("reopen-spare-ab: median over runs (each run's own p50 over its rounds)")
for turn in turns:
    for s in sides:
        logs = [f"{out}/{s}-t{turn}-{r}.log" for r in range(1, rounds + 1)]
        first = [v for v in (grab(p, r"^reopen-spare: first content p50 ([\d.]+) ms") for p in logs) if v is not None]
        live = [v for v in (grab(p, r"live \(newest answer, takes input\) p50 ([\d.]+) ms") for p in logs) if v is not None]
        task = [v for v in (grab(p, r"^reopen-spare adopt event's own task: p50 ([\d.]+) ms") for p in logs) if v is not None]
        heap = [v for v in (grab(p, r"JS heap p50 ([\d.]+) MB") for p in logs) if v is not None]
        nodes = [v for v in (grab(p, r"DOM nodes p50 ([\d.]+)") for p in logs) if v is not None]
        med = lambda xs: f"{statistics.median(xs):.1f}" if xs else "-"
        print(f"  TURNS={turn:<4} {s:<7} first content {med(first)} ms  live {med(live)} ms  adopt task {med(task)} ms  "
              f"spare heap {med(heap)} MB  nodes {med(nodes)}  runs {first}")
PY
echo "reopen-spare-ab: wrote $out"
