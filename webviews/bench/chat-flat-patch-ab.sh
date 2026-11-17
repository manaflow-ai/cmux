#!/usr/bin/env bash
# A/B of chat-100k-flat.bench.ts with and without another branch's pane change, in one run on one runner: side A is
# this checkout, side B this checkout with `git diff BASE HEAD -- webviews/src` applied (an open PR's change, from its
# merge base to its head), one launch of each in turn (A B A B ...), so host load falls on both alike. The bench and
# its stand-in daemon stay this checkout's. Each launch's log goes to $FAST_CHECKS_OUT (a cmux-ci test run), else a new
# temp dir; the summary prints each launch's settle, idle windows and ratios.
#   bench/chat-flat-patch-ab.sh BASE HEAD [rounds=2] [cases="long-many"] [rows=100000] [chats=20]
set -euo pipefail
cd "$(dirname "$0")/.."
base=${1:?usage: bench/chat-flat-patch-ab.sh BASE HEAD [rounds] [cases] [rows] [chats]}
head=${2:?usage: bench/chat-flat-patch-ab.sh BASE HEAD [rounds] [cases] [rows] [chats]}
rounds=${3:-2}
cases=${4:-long-many}
rows=${5:-100000}
chats=${6:-20}
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
mkdir -p "$out"

# Both commits' trees, fetched when they are not here (a CI checkout is shallow; the repository is public). A depth
# flag only in a checkout that is already shallow: in a full clone it would turn every worktree of it shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
for sha in "$base" "$head"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null ||
    git fetch -q ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha"
done
patch="$out/side-b.diff"
git diff "$base" "$head" -- src >"$patch"
git apply --check "$patch"
restore() { git apply -R "$patch" 2>/dev/null || true; }
trap restore EXIT

status=0
for round in $(seq 1 "$rounds"); do
  for case in $cases; do
    for side in a b; do
      [[ $side == b ]] && git apply "$patch"
      log="$out/ab-$case-$side-$round.log"
      echo "chat-flat-patch-ab: round $round $case side $side"
      CASES=$case RESIZE=0 PAINT=0 SETTLE_HEAP=1 bun bench/chat-100k-flat.bench.ts "$rows" "$chats" >"$log" 2>&1 || {
        status=$?
        echo "chat-flat-patch-ab: round $round $case side $side failed ($status)"
        tail -30 "$log"
      }
      [[ $side == b ]] && git apply -R "$patch"
      grep -E "CPU settled|settle heap|idle windows|_cpu_ratio|longest CPU settle|^[a-z_0-9]+ \| " "$log" | grep -v PERF_ROW || true
    done
  done
done
exit "$status"
