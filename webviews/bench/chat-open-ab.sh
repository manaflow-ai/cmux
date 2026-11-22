#!/usr/bin/env bash
# chat-open A/B: base and head of webviews/src interleaved on one machine, so a runner's speed drift
# lands on both sides (goals/chat-attach-p95.md). Usage, from webviews/:
#   bench/chat-open-ab.sh [BASE_REF] [ROUNDS] [PER]
# BASE_REF (default HEAD): the side "base" is webviews/src at that ref, "head" is the working tree's
# src (commits after BASE_REF and uncommitted edits). BASE_REF may instead be a patch file (base to head
# of webviews/src, `git diff BASE HEAD -- src` from webviews/): a CI job holding only the head commit
# has no ref to diff against, so the base comes in as that patch, reversed. Each round runs `PAIRED=1 FIXTURE=god` with PER
# timed loads per chat (default 3) on each side, base first on odd rounds and head first on even ones.
# Prints every round's paired rows and, per side, the median over rounds of each row. The working
# tree is restored on exit, even on failure.
set -euo pipefail
base_ref="${1:-HEAD}"
rounds="${2:-5}"
per="${3:-3}"
cd "$(dirname "$0")/.."
patch="$(mktemp -t chat-open-ab.XXXXXX.patch)"
log="$(mktemp -t chat-open-ab.XXXXXX.log)"
if [[ -f "$base_ref" ]]; then cp "$base_ref" "$patch"; else git diff --binary "$base_ref" -- src >"$patch"; fi
if [[ ! -s "$patch" ]]; then
  echo "chat-open-ab: webviews/src is the same at $base_ref and in the working tree; nothing to compare" >&2
  exit 2
fi
state=head
restore() {
  if [[ "$state" == base ]]; then git apply --binary "$patch"; fi
  rm -f "$patch"
}
trap restore EXIT
side() {
  local want="$1"
  if [[ "$want" == base && "$state" == head ]]; then git apply --binary -R "$patch"; state=base; fi
  if [[ "$want" == head && "$state" == base ]]; then git apply --binary "$patch"; state=head; fi
  PAIRED=1 FIXTURE=god bun bench/chat-open.bench.ts "$per" 2>&1 |
    grep -oE '"name":"chat_open_paired[^"]*\.(attach_to_latest|attach_per_dcl)","p50":[0-9.]+' |
    sed -E "s/\"name\":\"([^\"]*)\",\"p50\":([0-9.]+)/$want \1 \2/" | tee -a "$log"
}
for ((round = 1; round <= rounds; round++)); do
  echo "round $round of $rounds" >&2
  if ((round % 2)); then side base; side head; else side head; side base; fi
done
echo "median over $rounds rounds (base -> head):"
awk '{ v[$1 " " $2] = v[$1 " " $2] " " $3 } END { for (k in v) print k, v[k] }' "$log" | sort |
  while read -r which row values; do
    sorted=$(tr ' ' '\n' <<<"$values" | grep . | sort -g)
    n=$(wc -l <<<"$sorted")
    echo "$which $row $(sed -n "$(((n + 1) / 2))p" <<<"$sorted")"
  done |
  awk '{ m[$2, $1] = $3; rows[$2] = 1 } END { for (r in rows) printf "  %s: %s -> %s (%+.1f%%)\n", r, m[r, "base"], m[r, "head"], (m[r, "head"] / m[r, "base"] - 1) * 100 }'
rm -f "$log"
