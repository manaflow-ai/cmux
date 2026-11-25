#!/usr/bin/env bash
# A chat's open before and after a change, from one harness on one machine: bench/chat-open.bench.ts (the perf cron's
# `chat_open.compact.attach_to_latest` and `chat_open.god.compact.attach_to_latest`) at this checkout's pane and at
# BASE's pane (a detached worktree of BASE with this checkout's bench and node_modules, removed when done),
# interleaved ROUNDS times, the small chat and the god chat in each round. Each side's pane is built once (PANE_OUT).
#   bench/chat-open-ab.sh BASE [rounds=10] [per=2]
#   cmux-ci test --setup playwright -- bash webviews/bench/chat-open-ab.sh <full base sha> 10
# Each round runs every side and fixture once, PER timed opens each (after the bench's own warm open); the order
# of the sides turns every round, so a runner warming or tiring lands on every side alike. It prints, per side and
# fixture, attach_to_latest p50 and p95 over every open (nearest rank), the median DOMContentLoaded, and their
# ratio. BASE `-` measures this checkout only. Each run's log goes to OUT (default $FAST_CHECKS_OUT).
set -euo pipefail
base="${1:?usage: chat-open-ab.sh BASE [rounds] [per]}"
rounds="${2:-10}"
per="${3:-2}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
rel="$(git rev-parse --show-prefix)"
sides=(after)
declare -A dirs=([after]="$here")
trees=()
panes="$(mktemp -d)"
trap 'for t in "${trees[@]}"; do git -C "$here" worktree remove --force "$t" 2>/dev/null || true; done; rm -rf "$panes"' EXIT
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
  # The side's generated strings (gitignored, made by `bun install`'s postinstall), from its own sources.
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  dirs[before]="$tree/$rel"
  sides=(before after)
  echo "=== side before at $sha"
fi
# `run SIDE FIXTURE ROUND`: PER timed opens of FIXTURE (small or god) at SIDE's pane; its output to OUT.
run() {
  local side="$1" fixture="$2" round="$3" log="$out/$1-$2-$3.log" env=()
  [ "$fixture" = god ] && env=(FIXTURE=god)
  echo "=== $side $fixture round $round"
  (cd "${dirs[$side]}" && env "${env[@]}" PANE_OUT="$panes/$side" timeout 900 bun bench/chat-open.bench.ts "$per") \
    >"$log" 2>&1 || echo "=== $side $fixture FAILED"
  grep -E '^per round ' "$log" || true
}
n=${#sides[@]}
for round in $(seq 1 "$rounds"); do
  for k in $(seq 0 $((n - 1))); do
    side="${sides[$(((k + round - 1) % n))]}"
    if [ $((round % 2)) = 1 ]; then run "$side" small "$round"; run "$side" god "$round"
    else run "$side" god "$round"; run "$side" small "$round"; fi
  done
done
python3 - "$out" "$rounds" "${sides[@]}" <<'PY'
import math, statistics, sys
out, rounds, sides = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
def values(side, fixture, what):
    found = []
    for r in range(1, rounds + 1):
        try:
            for line in open(f"{out}/{side}-{fixture}-{r}.log"):
                if line.startswith(f"per round {what} ms: "):
                    found += [float(v) for v in line.split(": ", 1)[1].split()]
        except OSError:
            pass
    return found
def rank(sorted_values, q):
    return sorted_values[max(0, math.ceil(q * len(sorted_values)) - 1)]
print("chat-open-ab: attach_to_latest over every open (n), p50 and p95 by nearest rank; DOMContentLoaded median; "
      "attach_to_latest p50 / DCL")
print("side     fixture  n    a2l p50  a2l p95  dcl p50  ratio")
for fixture in ("small", "god"):
    for side in sides:
        a2l = sorted(values(side, fixture, "attach_to_latest"))
        dcl = values(side, fixture, "dom_content_loaded")
        if not a2l or not dcl:
            print(f"{side:<8} {fixture:<8} -")
            continue
        p50, p95, d = rank(a2l, 0.5), rank(a2l, 0.95), statistics.median(dcl)
        print(f"{side:<8} {fixture:<8} {len(a2l):<4} {p50:7.1f}  {p95:7.1f}  {d:7.1f}  {p50 / d:5.2f}x")
PY
echo "chat-open-ab: wrote $out"
