#!/usr/bin/env bash
# What a projected checkout holds in memory once nobody reads it: the mount's `git cat-file --batch`
# children and the server itself, right after a parallel read and after it sits idle. One harness
# for both arms of the idle-pool change (pass the before and after binaries as BIN).
#
# usage: idle-memory.sh BIN [READERS] [IDLE_S]
# env:   MIRROR (default ~/Projects/.wt-mirrors/manaflow-ai/cmux.git), COMMIT (default origin/feat-cmux-next),
#        ROOT (scratch folder, default ~/scratch/projection-idle)
#
# Prints one JSON line: children and their summed PSS and anonymous MB, and the server's own, at
# +5 s and at +IDLE_S s after the read ends, and the read's wall time. Needs FUSE (/dev/fuse,
# fusermount3) and sudo for other processes' smaps (falls back to plain reads of its own).
set -euo pipefail

BIN=${1:?usage: idle-memory.sh BIN [READERS] [IDLE_S]}
READERS=${2:-16}
IDLE_S=${3:-45}
MIRROR=${MIRROR:-$HOME/Projects/.wt-mirrors/manaflow-ai/cmux.git}
COMMIT=${COMMIT:-$(git --git-dir "$MIRROR" rev-parse refs/remotes/origin/feat-cmux-next)}
ROOT=${ROOT:-$HOME/scratch/projection-idle}
NAME=pidle-$$
AT=$ROOT/$NAME/mnt
KEEP=$ROOT/$NAME/keep
mkdir -p "$AT" "$KEEP"

cleanup() {
  "$BIN" git-unmount --at "$AT" >/dev/null 2>&1 || fusermount3 -uz "$AT" 2>/dev/null || true
  [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true
  git --git-dir "$MIRROR" worktree remove --force "$AT" >/dev/null 2>&1 || true
  git --git-dir "$MIRROR" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$BIN" git-mount --git-dir "$MIRROR" --commit "$COMMIT" --at "$AT" --keep "$KEEP" --name "$NAME" \
  --ready-file "$KEEP/ready.json" --fresh >"$ROOT/$NAME/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 600); do [ -s "$KEEP/ready.json" ] && break; sleep 0.1; done
[ -s "$KEEP/ready.json" ] || { echo "mount never came up; see $ROOT/$NAME/server.log" >&2; exit 1; }

# What an agent does to a checkout: a search or a build reads many files at once.
start=$(date +%s.%N)
(cd "$AT" && git ls-files -z | xargs -0 -P "$READERS" -n 64 cat >/dev/null 2>&1) || true
read_s=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')

smaps() { sudo -n cat "/proc/$1/smaps_rollup" 2>/dev/null || cat "/proc/$1/smaps_rollup" 2>/dev/null; }
sample() {
  local kids pss=0 anon=0 n=0 spss sanon
  kids=$(pgrep -P "$SERVER" -x git || true)
  for k in $kids; do
    read -r p a < <(smaps "$k" | awk '/^Pss:/{p=$2}/^Anonymous:/{a=$2} END{print p+0, a+0}')
    pss=$((pss + p)); anon=$((anon + a)); n=$((n + 1))
  done
  read -r spss sanon < <(smaps "$SERVER" | awk '/^Pss:/{p=$2}/^Anonymous:/{a=$2} END{print p+0, a+0}')
  printf '{"git":%d,"git_pss_mb":%d,"git_anon_mb":%d,"server_pss_mb":%d,"server_anon_mb":%d}' \
    "$n" $((pss / 1024)) $((anon / 1024)) $((spss / 1024)) $((sanon / 1024))
}

sleep 5
hot=$(sample)
sleep $((IDLE_S - 5))
idle=$(sample)

# A read after the idle time still works (and starts a new process where the pool was emptied).
again_start=$(date +%s.%N)
head -c 64 "$AT/README.md" >/dev/null
again_s=$(awk -v a="$again_start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.3f", b - a }')

printf '{"bin":"%s","commit":"%s","readers":%d,"read_s":%s,"at_5s":%s,"at_%ds":%s,"read_after_idle_s":%s}\n' \
  "$BIN" "${COMMIT:0:12}" "$READERS" "$read_s" "$hot" "$IDLE_S" "$idle" "$again_s"
