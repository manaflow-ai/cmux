#!/usr/bin/env bash
# A/B of chat-open.bench.ts with and without a branch's pane change, in one run on one runner, as
# chat-flat-patch-ab.sh does for chat-100k-flat: side A is this checkout, side B this checkout with
# `git diff BASE HEAD -- webviews/src` applied, one launch of each in turn (A B A B ...) for the small
# chat and the god chat, so host load falls on both alike. Each launch prints its attach_to_latest and
# DOMContentLoaded rows (the second is the runner's own speed); the summary prints each side's median.
#   bench/chat-open-patch-ab.sh BASE HEAD [rounds=4] [opens=5]
set -euo pipefail
cd "$(dirname "$0")/.."
base=${1:?usage: bench/chat-open-patch-ab.sh BASE HEAD [rounds] [opens]}
head=${2:?usage: bench/chat-open-patch-ab.sh BASE HEAD [rounds] [opens]}
rounds=${3:-4}
opens=${4:-5}
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
mkdir -p "$out"

# Both commits' trees, fetched when they are not here (chat-flat-patch-ab.sh).
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

rows="$out/ab-rows.txt"
: >"$rows"
status=0
for round in $(seq 1 "$rounds"); do
  for fixture in small god; do
    # Alternate which side goes first, so a drift in the runner falls on both.
    sides="a b"
    ((round % 2 == 0)) && sides="b a"
    for side in $sides; do
      [[ $side == b ]] && git apply "$patch"
      log="$out/ab-$fixture-$side-$round.log"
      env $([[ $fixture == god ]] && echo FIXTURE=god) bun bench/chat-open.bench.ts "$opens" 300 >"$log" 2>&1 || {
        status=$?
        echo "chat-open-patch-ab: round $round $fixture side $side failed ($status)"
        tail -30 "$log"
      }
      [[ $side == b ]] && git apply -R "$patch"
      grep -oE '"name":"chat_open[a-z.]*\.(attach_to_latest|dom_content_loaded)","p50":[0-9.]+' "$log" |
        sed -E "s/^\"name\":\"([^\"]+)\",\"p50\":/$fixture $side \1 /" | tee -a "$rows"
    done
  done
done
echo "chat-open-patch-ab: median of $rounds launches (each the median of $opens opens), A = base, B = head"
for fixture in small god; do
  for stage in attach_to_latest dom_content_loaded; do
    for side in a b; do
      grep -E "^$fixture $side [a-z_.]*\.$stage " "$rows" | awk '{print $4}' | sort -n |
        awk -v l="$fixture $stage $side" '{v[NR]=$1} END {if (NR) printf "%s %.1f ms (n=%d)\n", l, (NR%2 ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2), NR}'
    done
  done
done
exit "$status"
