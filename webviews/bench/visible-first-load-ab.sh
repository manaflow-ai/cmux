#!/usr/bin/env bash
# Before and after a visible-first change, from one harness on one machine: bench/visible-first-load.bench.ts
# at this checkout's pane and at BASE's pane, interleaved by round (after, before, after, before, ...), so both
# arms see the same host. BASE is a detached worktree with this checkout's bench and node_modules, and with
# the bench's load hook (cmuxAcpmuxDebug.sessionChurn: mock.ts, loadDebug.ts, debug.ts) as this checkout has
# it, so the arms differ only in what the change did. Removed when done. Writes after-N.json and before-N.json
# to OUT (default $FAST_CHECKS_OUT) and prints each round's VISIBLE-FIRST rows.
#   bench/visible-first-load-ab.sh BASE [rounds=2] [bench flags...]
#   cmux-ci test --setup playwright -- bash webviews/bench/visible-first-load-ab.sh <base sha>
set -euo pipefail
base="${1:?usage: visible-first-load-ab.sh BASE [rounds] [bench flags]}"
rounds="${2:-2}"
shift $(( $# >= 2 ? 2 : 1 ))
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
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
# The load hook only: the base keeps everything else it had.
for f in mock.ts loadDebug.ts debug.ts; do
  cp "$here/src/agent-session/acpmux/$f" "$tree/$rel/src/agent-session/acpmux/$f"
done
(cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
(cd "$here" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null) || true
run() {
  local label="$1" dir="$2" round="$3"
  shift 3
  echo "=== $label round $round"
  (cd "$dir" && bun bench/visible-first-load.bench.ts --dir "$dir" --json "$out/$label-$round.json" "$@") ||
    echo "=== $label round $round FAILED"
}
for round in $(seq 1 "$rounds"); do
  run after "$here" "$round" "$@"
  run before "$tree/$rel" "$round" "$@"
done
echo "visible-first-load-ab: wrote $out"
