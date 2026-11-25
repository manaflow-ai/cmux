#!/usr/bin/env bash
# Time to a working checkout of one commit on a machine that has no copy of the repo, three ways,
# same origin, same commands: `full` (git clone --depth 1, which checks every file out), `eager`
# (cmux-projection git-mount on a blobless clone, which fetches every blob before it mounts) and
# `lazy` (git-mount --lazy on the same blobless clone, each blob fetched on first read).
#
# Two more modes model an origin that does not answer protocol v2 `object-info` (GitHub's does
# not), so sizes come from elsewhere: `lazy-none` (no listing: the mount fetches every blob to size
# it) and `lazy-listing` (a listing of an older commit, BASE, as a machine image saves one: only
# the blobs added since BASE are fetched). MODES picks and orders them (default: all five).
#
# Per mode it prints: ready_s (clone plus mount), status_s (the first `git status`), read_s (one
# file, then every file of one crate folder), the blobs still missing and the git dir's size.
#
#   scripts/measure/projection-lazy-git.sh BIN REPO [REV]
#     BIN   a built cmux-projection (cargo build -p cmux-projection --bin cmux-projection)
#     REPO  any local git repo; its REV (default HEAD) becomes the origin, a file:// bare repo
#           with uploadpack.allowFilter and transfer.advertiseObjectInfo set
#   FILE=PATH reads that file and its folder (default: the first file two folders down)
#   BASE=REV  the listing's commit for lazy-listing (default REV~50, from REPO)
#   MODES="full eager lazy lazy-none lazy-listing" the modes to run, in order
#
# On the fleet: cmux-ci run --class linux --measurement --script scripts/measure/projection-lazy-git.sh \
#   --ref SHA (after building BIN in the same script step). Needs /dev/fuse and fusermount3.
set -euo pipefail
BIN=$(realpath "$1"); REPO=$(realpath "$2"); REV=${3:-HEAD}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/projection-lazy-git.XXXXXX")
trap 'for m in "$WORK"/run-*/mnt; do fusermount3 -u "$m" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT
git clone -q --bare --depth 1 --no-local --revision="$(git -C "$REPO" rev-parse "$REV")" "file://$REPO" "$WORK/origin.git"
git -C "$WORK/origin.git" update-ref HEAD "$(git -C "$REPO" rev-parse "$REV")" 2>/dev/null || true
for key in uploadpack.allowFilter uploadpack.allowAnySHA1InWant; do
  git -C "$WORK/origin.git" config "$key" true
done
ORIGIN=file://$WORK/origin.git
FILE=${FILE:-}
[ -n "$FILE" ] || FILE=$(git -C "$WORK/origin.git" ls-tree -r --name-only HEAD | awk -F/ 'NF>2 && !found {print; found=1}')
FOLDER=$(dirname "$FILE")
echo "origin: $(git -C "$WORK/origin.git" rev-parse HEAD), $(git -C "$WORK/origin.git" ls-tree -r HEAD | wc -l) paths; read: $FILE, then $FOLDER/*"
BASE=${BASE:-$REV~50}
git -C "$REPO" ls-tree -r -l -z --full-tree "$BASE" > "$WORK/listing"
echo "listing: $BASE ($(git -C "$REPO" rev-parse "$BASE")), $(tr -cd '\0' < "$WORK/listing" | wc -c) paths, $(du -k "$WORK/listing" | cut -f1) KiB"
now() { date +%s.%N; }
for mode in ${MODES:-full eager lazy lazy-none lazy-listing}; do
  # Only `lazy` has an origin that answers object-info.
  git -C "$WORK/origin.git" config transfer.advertiseObjectInfo "$([ "$mode" = lazy ] && echo true || echo false)"
  run=$WORK/run-$mode; mkdir -p "$run"; cd "$run"
  t0=$(now)
  if [ "$mode" = full ]; then
    git -c advice.detachedHead=false clone -q --depth 1 "$ORIGIN" work; at=$run/work; gd=$at/.git
  else
    git clone -q --bare --depth 1 --filter=blob:none "$ORIGIN" mirror.git
    git -C mirror.git config extensions.worktreeConfig true
    at=$run/mnt; gd=$run/mirror.git; mkdir -p "$at"
    flag=()
    case $mode in
      lazy | lazy-none) flag=(--lazy) ;;
      lazy-listing) flag=(--lazy --sizes "$WORK/listing") ;;
    esac
    # The mount prints one JSON line on stderr once it serves: a blocking read, no poll.
    coproc MOUNT { "$BIN" git-mount --git-dir mirror.git --commit HEAD --at "$at" --keep "$run/keep" --fresh "${flag[@]}" 2>&1 >/dev/null; }
    pid=$MOUNT_PID
    read -r ready <&"${MOUNT[0]}"
  fi
  t1=$(now)
  lines=$(git -C "$at" status --porcelain | wc -l)
  t2=$(now)
  head -c 100 "$at/$FILE" >/dev/null
  t3=$(now)
  find "$at/$FOLDER" -maxdepth 1 -type f -exec cat {} + >/dev/null
  t4=$(now)
  missing=$(git -C "$gd" rev-list --objects --no-walk --missing=print HEAD | grep -c '^?' || true)
  printf '%-12s ready_s=%.2f status_s=%.2f first_read_s=%.3f folder_read_s=%.3f to_first_status_s=%.2f status_lines=%s blobs_missing=%s git_dir_kib=%s\n' \
    "$mode" "$(echo "$t1-$t0" | bc)" "$(echo "$t2-$t1" | bc)" "$(echo "$t3-$t2" | bc)" "$(echo "$t4-$t3" | bc)" \
    "$(echo "$t2-$t0" | bc)" "$lines" "$missing" "$(du -sk "$gd" | cut -f1)"
  if [ "$mode" != full ]; then
    echo "      mount: $ready"
    fusermount3 -u "$at"; wait "$pid" 2>/dev/null || true
  fi
  cd "$WORK"
done
