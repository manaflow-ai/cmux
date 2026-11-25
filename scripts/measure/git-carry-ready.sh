#!/usr/bin/env bash
# git-carry-ready.sh: repo-ready time of a git seed, today's clone (git-seed-v1) against carry
# (git-seed-carry-v1, cmux-tui-core git_seed/carry.rs).
#
# Repo-ready = an empty destination folder becomes a usable checkout at the sender's HEAD with
# its uncommitted changes (an unpushed commit, staged and unstaged edits, an untracked file),
# HEAD on the sender's branch, the index equal to the sender's.
#
# Both modes run the exact git steps the machine's seed runs (git_seed/run.rs), with the
# machine's git environment (no global or system config, so no insteadOf to a local mirror,
# no alternates, no credential helper):
#   clone: git clone --filter=blob:none --no-checkout URL, then the bundle, then the checkout
#          (which downloads the base's blobs from GitHub in one batch).
#   carry: the sender's `pack-objects --revs` of `--shallow BASE` + BASE (deltas reused), the
#          pack copied into a private file as the daemon copies an upload, `git init`,
#          `index-pack --strict`, `.git/shallow`, the missing-object check, then the same
#          bundle and checkout with every blob already local.
#   borrow (MIRROR=a blobless bare mirror of URL, as `wt` keeps one; git_seed/borrow.rs):
#          `git init`, the mirror's objects in `objects/info/alternates`, its shallow file,
#          `origin` the one promisor (blob:none), the missing-object check, then the same
#          bundle and checkout with every object read through the mirror.
#   deepen: after a borrow, the first DEEPEN (default 20) commits of history on demand
#          (`fetch --deepen`, the boundary kept), timed alone against `fetch --unshallow`
#          when UNSHALLOW=1.
# MODES picks them (default "clone carry"; "borrow deepen" needs MIRROR). DURESS=N runs N
# seeds of each mode at once and prints the slowest (the machine under N concurrent seeds).
# The carry time includes making the pack on the sender. It does NOT include the upload over
# the Mac-to-machine link: the script prints the pack's bytes so the upload can be added for a
# given link (bytes / rate).
#
# Usage: [MODES=..] [MIRROR=..] [DURESS=N] scripts/measure/git-carry-ready.sh SENDER [RUNS] [URL]
#   SENDER  a full (not partial) clone of URL; untouched: the script works in a worktree of it.
#   RUNS    runs per mode (default 3); prints each run and the median.
#   URL     default https://github.com/manaflow-ai/cmux.git
# Each run's destination is a fresh empty folder under $WORK (default a mktemp dir), removed
# after the run. Exit 0 when every run's checkout matched the sender, else 1.
set -euo pipefail

SENDER=${1:?usage: git-carry-ready.sh SENDER [RUNS] [URL]}
RUNS=${2:-3}
URL=${3:-https://github.com/manaflow-ai/cmux.git}
WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/git-carry-ready.XXXXXX")}
GIT=${GIT:-/usr/bin/git}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
g() { "$GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }
now() { date +%s.%N; }
ok=0

if [ "$(g -C "$SENDER" config --get extensions.partialClone || true)" != "" ]; then
  echo "SENDER is a partial clone; carry needs every blob of the base" >&2
  exit 2
fi

# The sender's state: a worktree at the remote's default branch with local work on top.
# BASE=SHA pins it (a SENDER without a reachable origin); else the remote's default branch.
if [ -z "${BASE:-}" ]; then
  g -C "$SENDER" fetch -q origin
  BASE=$(g -C "$SENDER" rev-parse origin/HEAD 2>/dev/null || g -C "$SENDER" rev-parse origin/main)
fi
SRC=$WORK/sender-wt
g -C "$SENDER" worktree add -q -B carry-measure "$SRC" "$BASE"
trap 'g -C "$SENDER" worktree remove --force "$SRC" >/dev/null 2>&1 || true; g -C "$SENDER" branch -q -D carry-measure >/dev/null 2>&1 || true' EXIT
echo "unpushed $(date)" >> "$SRC/README.md"
g -C "$SRC" -c user.name=m -c user.email=m@x commit -q -am "unpushed"
echo "staged" >> "$SRC/CLAUDE.md"; g -C "$SRC" add CLAUDE.md
echo "unstaged" >> "$SRC/CLAUDE.md"
echo "untracked" > "$SRC/carry-untracked.txt"
HEAD=$(g -C "$SRC" rev-parse HEAD)
seed_commit() { GIT_AUTHOR_NAME="cmux seed" GIT_AUTHOR_EMAIL=seed@cmux.invalid GIT_AUTHOR_DATE="946684800 +0000" \
  GIT_COMMITTER_NAME="cmux seed" GIT_COMMITTER_EMAIL=seed@cmux.invalid GIT_COMMITTER_DATE="946684800 +0000" \
  g -C "$SRC" commit-tree -p "$2" -m "$3" "$1"; }
INDEX=$(seed_commit "$(g -C "$SRC" write-tree)" "$HEAD" "cmux seed index")
TMPIDX=$WORK/work.index; cp "$(g -C "$SRC" rev-parse --absolute-git-dir)/index" "$TMPIDX"
GIT_INDEX_FILE=$TMPIDX g -C "$SRC" add -A
WORKC=$(seed_commit "$(GIT_INDEX_FILE=$TMPIDX g -C "$SRC" write-tree)" "$INDEX" "cmux seed work")
g -C "$SRC" update-ref refs/cmux-seed/head "$HEAD"
g -C "$SRC" update-ref refs/cmux-seed/index "$INDEX"
g -C "$SRC" update-ref refs/cmux-seed/work "$WORKC"
BUNDLE=$WORK/seed.bundle
g -C "$SRC" bundle create -q "$BUNDLE" refs/cmux-seed/head refs/cmux-seed/index refs/cmux-seed/work "^$BASE"
BUNDLE_BYTES=$(stat -c %s "$BUNDLE")
echo "url=$URL base=$BASE head=$HEAD index=$INDEX work=$WORKC bundle_bytes=$BUNDLE_BYTES git=$($GIT --version)"

# The bundle and checkout steps both modes share (run.rs apply_bundle, check_out_work,
# finish_checkout).
finish() {
  local d=$1
  g -C "$d" bundle verify -q "$BUNDLE" >/dev/null 2>&1
  g -C "$d" -c protocol.file.allow=always -c transfer.fsckObjects=true fetch -q --no-tags \
    --no-write-fetch-head "$BUNDLE" "+refs/cmux-seed/*:refs/cmux-seed-incoming/*"
  g -C "$d" checkout -q --force -B carry-measure "$HEAD" --
  g -C "$d" read-tree --reset -u "$WORKC"
  g -C "$d" read-tree --reset "$INDEX"
}

check() {
  local d=$1
  [ "$(g -C "$d" rev-parse HEAD)" = "$HEAD" ] &&
    [ "$(g -C "$d" write-tree)" = "$(g -C "$SRC" write-tree)" ] &&
    [ "$(g -C "$d" status --porcelain=v1 --untracked-files=all)" = "$(g -C "$SRC" status --porcelain=v1 --untracked-files=all)" ]
}

pack_bytes() { find "$1/.git/objects" -type f \( -name '*.pack' -o -path '*/objects/??/*' \) -printf '%s\n' | awk '{s+=$1} END {print s+0}'; }

run_clone() {
  local d=$1
  g clone -q --filter=blob:none --no-checkout -- "$URL" "$d"
  finish "$d"
}

run_carry() {
  local d=$1 pack=$1.upload.pack
  printf -- '--shallow %s\n%s\n' "$BASE" "$BASE" |
    g -C "$SRC" pack-objects --revs --stdout -q --delta-base-offset > "$pack"
  CARRY_BYTES=$(stat -c %s "$pack")
  mkdir -p "$d"
  g init -q -- "$d"
  g -C "$d" remote add origin "$URL"
  echo "$BASE" > "$d/.git/shallow"
  # The daemon's private copy of the upload, then into the object store.
  cp "$pack" "$d/.git/objects/pack/tmp_carry.pack"; rm -f "$pack"
  local name
  name=$(g -C "$d" index-pack --strict "$d/.git/objects/pack/tmp_carry.pack")
  mv "$d/.git/objects/pack/tmp_carry.pack" "$d/.git/objects/pack/pack-$name.pack"
  mv "$d/.git/objects/pack/tmp_carry.idx" "$d/.git/objects/pack/pack-$name.idx"
  [ ! -f "$d/.git/objects/pack/tmp_carry.rev" ] || mv "$d/.git/objects/pack/tmp_carry.rev" "$d/.git/objects/pack/pack-$name.rev"
  if g -C "$d" rev-list --objects --no-walk --missing=print "$BASE" | grep -q '^?'; then
    echo "carry pack lacks objects" >&2; return 1
  fi
  finish "$d"
}

run_borrow() {
  local d=$1
  [ -n "${MIRROR:-}" ] || { echo "borrow needs MIRROR" >&2; return 1; }
  [ "$(g --git-dir="$MIRROR" config --get remote.origin.url | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')" = \
    "$(printf %s "$URL" | sed -E 's#^https://github.com/##; s#\.git$##')" ] || { echo "MIRROR is another repository" >&2; return 1; }
  mkdir -p "$d"
  g init -q -- "$d"
  echo "$(cd "$MIRROR/objects" && pwd -P)" > "$d/.git/objects/info/alternates"
  [ ! -f "$MIRROR/shallow" ] || cp "$MIRROR/shallow" "$d/.git/shallow"
  g -C "$d" remote add origin "$URL"
  g -C "$d" config remote.origin.promisor true
  g -C "$d" config remote.origin.partialclonefilter blob:none
  g -C "$d" config core.repositoryformatversion 1
  g -C "$d" config extensions.partialClone origin
  if g -C "$d" rev-list --objects --no-walk --missing=print "$BASE" | grep -q '^?'; then
    echo "mirror lacks objects of the base" >&2; return 1
  fi
  finish "$d"
}

DEEPEN=${DEEPEN:-20}
run_deepen() {
  local d=$1
  run_borrow "$d" || return 1
  [ -f "$d/.git/shallow" ] || echo "$BASE" > "$d/.git/shallow"
  local t0 t1
  t0=$(now)
  g -C "$d" fetch -q --no-tags --deepen="$DEEPEN" origin "$BASE"
  t1=$(now)
  DEEPEN_S=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f", b - a}')
  if [ "${UNSHALLOW:-0}" = 1 ]; then
    t0=$(now); g -C "$d" fetch -q --no-tags --unshallow origin; t1=$(now)
    DEEPEN_S="$DEEPEN_S unshallow_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f", b - a}')"
  fi
}

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

DURESS=${DURESS:-0}
for mode in ${MODES:-clone carry}; do
  if [ "$DURESS" -gt 1 ]; then
    t0=$(now); pids=()
    for j in $(seq 1 "$DURESS"); do
      ( set +e; CARRY_BYTES=0; "run_$mode" "$WORK/duress-$mode-$j" >/dev/null 2>&1; echo $? > "$WORK/duress-$mode-$j.rc" ) & pids+=($!)
    done
    wait ${pids[@]+"${pids[@]}"}; t1=$(now)
    bad=0; for j in $(seq 1 "$DURESS"); do
      { [ "$(cat "$WORK/duress-$mode-$j.rc")" = 0 ] && check "$WORK/duress-$mode-$j"; } || bad=$((bad + 1))
      rm -rf "$WORK/duress-$mode-$j" "$WORK/duress-$mode-$j.rc"
    done
    [ $bad -eq 0 ] || ok=1
    echo "$mode duress=$DURESS all_ready_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f", b - a}') failed=$bad load=$(cut -d' ' -f1 /proc/loadavg)"
    continue
  fi
  times=()
  for i in $(seq 1 "$RUNS"); do
    d=$WORK/dest-$mode-$i
    CARRY_BYTES=0 DEEPEN_S=
    t0=$(now)
    set +e; "run_$mode" "$d"; rc=$?; set -e
    t1=$(now)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f", b - a}')
    if [ $rc -eq 0 ] && check "$d"; then match=yes; else match=no; ok=1; fi
    echo "$mode run=$i rc=$rc ready_s=$secs matches_sender=$match objects_bytes=$(pack_bytes "$d") carry_pack_bytes=$CARRY_BYTES shallow=$([ -f "$d/.git/shallow" ] && echo yes || echo no)${DEEPEN_S:+ deepen_${DEEPEN}_s=$DEEPEN_S}"
    times+=("$secs")
    rm -rf "$d"
  done
  echo "$mode median_ready_s=$(printf '%s\n' ${times[@]+"${times[@]}"} | median) runs=$RUNS"
done
rm -rf "$WORK/seed.bundle" "$WORK/work.index"
exit $ok
