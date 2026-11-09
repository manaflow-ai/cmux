#!/usr/bin/env bash
# Before and after a send change, from one harness on one machine: bench/send-status-shift.bench.ts at
# this checkout's pane, then at BASE's pane (a detached worktree of BASE, with this checkout's bench
# and node_modules, removed when done), in its two modes (an open chat, a new chat's composer). Writes
# before-MODE.json and after-MODE.json to OUT (default $FAST_CHECKS_OUT). The checkout itself is never
# touched, so edits in it, staged or not, stay as they are (review of #39781).
#   bench/send-status-ab.sh BASE [rounds=3]
#   cmux-ci test --setup playwright -- bash webviews/bench/send-status-ab.sh <base sha>
set -euo pipefail
base="${1:?usage: send-status-ab.sh BASE [rounds]}"
rounds="${2:-3}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
# `run LABEL DIR`: the bench at the webviews of DIR.
run() {
  local label="$1" dir="$2" mode
  for mode in open new-chat; do
    local flag=()
    [ "$mode" != open ] && flag=("--$mode")
    echo "=== $label $mode"
    (cd "$dir" && bun bench/send-status-shift.bench.ts "$rounds" --engines chromium,webkit --think-ms 1500 \
      --start-ms 1500 "${flag[@]}" --json "$out/$label-$mode.json") || echo "=== $label $mode FAILED"
  done
}
run after "$here"
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$base"
tree="$(mktemp -d)/base"
trap 'git -C "$here" worktree remove --force "$tree" 2>/dev/null || true' EXIT
git worktree add -q --detach "$tree" "$base"
rel="$(git rev-parse --show-prefix)"
rm -rf "$tree/$rel/bench"
cp -R "$here/bench" "$tree/$rel/bench"
ln -s "$here/node_modules" "$tree/$rel/node_modules"
run before "$tree/$rel"
echo "send-status-ab: wrote $out"
