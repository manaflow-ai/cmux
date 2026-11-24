#!/usr/bin/env bash
# Cloud checkout timing: how soon a chat can read files when the checkout downloads in the
# background (cmux-tui-core git_seed `play_while_filling`), against today's whole checkout.
# Leo (ask-ef35ebdc1d): "play partially as it downloads in the background".
#   scripts/measure/cloud-partial-hydrate.sh full|play|kill     (one JSON line per step)
# full: blobless clone, then the whole checkout (every tool waits for it today).
# play: clone, head (head_patterns), hot files (what HEAD's last 50 commits changed), then
#   WORK's missing blobs fetched in chunks in the background while one want (docs/cloud/)
#   is served by its own reapply, then the whole tree from local objects.
# kill: as play, the download SIGKILLed after KILL_AFTER s (default 15), then started again:
#   it fetches only what is still missing.
# Network-bound, against GitHub (URL, REF); run it on the machine you want numbers for.
set -euo pipefail
MODE=${1:?mode}
REF=${REF:-feat-cmux-next}
URL=${URL:-https://github.com/manaflow-ai/cmux}
CHUNK=${CHUNK:-4000}
ROOT=${ROOT:-${TMPDIR:-/tmp}/cloud-partial-hydrate}
mkdir -p "$ROOT"
DIR="$ROOT/$MODE-$(date +%s)"
export GIT_TERMINAL_PROMPT=0
now() { date +%s.%N; }
T0=$(now)
step() {
  local end; end=$(now)
  printf '{"mode":"%s","step":"%s","s":%.3f,"since_start_s":%.3f,"objects_bytes":%s,"files":%s,"missing":%s}\n' \
    "$MODE" "$1" "$(echo "$end - $2" | bc)" "$(echo "$end - $T0" | bc)" \
    "$(du -sb "$DIR/.git/objects" | cut -f1)" \
    "$(git -C "$DIR" ls-files -t 2>/dev/null | grep -c '^H ' || true)" "$(missing | wc -l)"
}
missing() {
  git -C "$DIR" ls-tree -r --format='%(objecttype) %(objectname)' HEAD | awk '$1=="blob"{print $2}' |
    GIT_NO_LAZY_FETCH=1 git -C "$DIR" cat-file --batch-check='%(objectname)' 2>/dev/null | awk '$2=="missing"{print $1}'
}
fetch_rest() {
  local list; list=$(mktemp)
  missing > "$list"
  split -l "$CHUNK" "$list" "$list."
  for c in "$list".*; do
    git -C "$DIR" -c fetch.negotiationAlgorithm=noop fetch -q origin --no-tags --no-write-fetch-head \
      --recurse-submodules=no --filter=blob:none --stdin < "$c"
  done
  rm -f "$list" "$list".*
}
s=$(now)
git clone -q --filter=blob:none --no-checkout --single-branch --branch "$REF" -- "$URL" "$DIR"
step clone "$s"
cd "$DIR"
if [ "$MODE" = full ]; then
  s=$(now); git checkout -q --force --detach HEAD --; step checkout_whole "$s"; exit 0
fi
HEAD_SHA=$(git rev-parse HEAD)
git config core.sparseCheckout true
git config core.sparseCheckoutCone false
mkdir -p .git/info
pat() { printf '%s' "$1" > .git/info/sparse-checkout; }
P=$'/*\n!/*/\n'
for d in .agents .claude .codex .cursor .gemini .github .vscode .devcontainer; do P+="/$d/"$'\n'"/$d/**"$'\n'; done
pat "$P"
s=$(now); git checkout -q --force --detach "$HEAD_SHA" --; step head "$s"
while read -r f; do [ -n "$f" ] && P+="/$f"$'\n'; done < <(git log -n 50 --name-only --format= "$HEAD_SHA" | grep -v '^$' | sort -u)
pat "$P"
s=$(now); git sparse-checkout reapply; step hot "$s"

s=$(now)
if [ "$MODE" = kill ]; then
  export -f missing fetch_rest; export DIR CHUNK
  ( timeout -s KILL "${KILL_AFTER:-15}" bash -c fetch_rest ) || true
  step fetch_killed "$s"
  s=$(now); fetch_rest; step fetch_resumed "$s"
else
  fetch_rest &
  BF=$!
  sleep 3
  P+=$'/docs/cloud/\n!/docs/cloud/*/\n'
  pat "$P"
  w=$(now); git sparse-checkout reapply; step want_docs_cloud_during_fetch "$w"
  wait "$BF"; step fetch_rest "$s"
fi
pat $'/*\n'
s=$(now); git sparse-checkout reapply; git sparse-checkout disable; step whole_from_local "$s"
