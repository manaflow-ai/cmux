#!/usr/bin/env bash
# Before and after a transcript change, from one harness in one job: composer-typing.bench.ts in stream mode at
# 6,000 rows, this checkout's pane against BASE's (a detached worktree of BASE, with this checkout's bench and
# node_modules, removed when done), interleaved with a base-against-base noise floor (composer-arms.ts), idle and
# with every core saturated (--cpu-load, load-modes.json L4). Per arm: keydown to frame, style and task time, GC
# time and heap, and the transcript's and rows' renders per streamed event.
#   bench/transcript-stream-ab.sh BASE [rounds=4]
#   cmux-ci test --setup playwright -- bash webviews/bench/transcript-stream-ab.sh <base sha>
set -euo pipefail
base="${1:?usage: transcript-stream-ab.sh BASE [rounds]}"
rounds="${2:-4}"
cd "$(dirname "$0")/.."
here="$(pwd)"
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
for load in idle cpu-load; do
  flag=()
  [ "$load" = cpu-load ] && flag=(--cpu-load)
  echo "=== $load"
  bun bench/composer-typing.bench.ts --lengths 6000 --modes stream --keys 40 --gc --rounds "$rounds" \
    --arms "base=$tree/$rel,head=$here" "${flag[@]}" || echo "=== $load FAILED"
done
