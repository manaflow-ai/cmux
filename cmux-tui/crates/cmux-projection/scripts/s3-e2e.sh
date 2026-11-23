#!/usr/bin/env bash
# usage: s3-e2e.sh CMUX_PROJECTION_BIN SOURCE_DIR   (Linux, FUSE)
# End to end: rclone's S3 server (SigV4 auth on) as the bucket; push a repo's blobs with
# `cmux-projection s3-push`; a blobless mirror fills them through the chain's s3 tier.
set -euo pipefail
BIN=${1:?cmux-projection binary}
SRC=${2:?a folder to commit as the test repo}
W=$(mktemp -d /tmp/s3-e2e.XXXXXX); mkdir -p "$W/data/blobs"
RCLONE=${RCLONE:-rclone}  # rclone >= 1.65 (serve s3); the run below used v1.76.0
PORT=19${RANDOM:0:3}
"$RCLONE" serve s3 --auth-key AKIDE2E,e2e-secret-key --addr 127.0.0.1:$PORT "$W/data" >"$W/rclone.log" 2>&1 &
RPID=$!; trap 'kill $RPID 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# The test repo: a full store, then a blobless bare clone of it (what a wt mirror is).
git init -q "$W/full"; cp -r "$SRC"/. "$W/full/"; git -C "$W/full" add -A
git -C "$W/full" -c user.name=e2e -c user.email=e2e@local commit -qm e2e
git -C "$W/full" config uploadpack.allowFilter true
COMMIT=$(git -C "$W/full" rev-parse HEAD)
git clone -q --bare --filter=blob:none "file://$W/full" "$W/thin.git"
echo "repo: $(git -C "$W/full" ls-tree -r HEAD | wc -l) files, $(du -sh "$W/full" --exclude=.git | cut -f1)"

export CMUX_PROJECTION_S3_REGION=us-east-1
BASE=http://127.0.0.1:$PORT/blobs/fleet
echo "--- wrong key is refused"
AWS_ACCESS_KEY_ID=AKIDE2E AWS_SECRET_ACCESS_KEY=wrong "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD 2>&1 | tail -2 || true
export AWS_ACCESS_KEY_ID=AKIDE2E AWS_SECRET_ACCESS_KEY=e2e-secret-key
echo "--- push"; "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD
echo "--- push again (bucket holds them)"; "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD

echo "--- blobless mirror fills from the bucket (no peers, no git fetch source)"
before=$(git -C "$W/thin.git" count-objects -v | awk '/^count/{print $2}')
# Point origin nowhere, so anything the bucket misses fails loudly instead of fetching.
git -C "$W/thin.git" remote set-url origin "file:///nonexistent"
mkdir -p "$W/mnt"
export CMUX_PROJECTION_S3_URL=$BASE
start=$(date +%s%N)
"$BIN" git-mount --git-dir "$W/thin.git" --commit "$COMMIT" --at "$W/mnt" --keep "$W/keep" --ready-file "$W/ready" >"$W/mount.log" 2>&1 &
MPID=$!
for _ in $(seq 600); do [ -s "$W/ready" ] && break; kill -0 $MPID 2>/dev/null || break; sleep 0.1; done
echo "wall to ready: $(( ($(date +%s%N)-start)/1000000 )) ms"
grep -E "missing blobs|total_ms|error" "$W/mount.log" || cat "$W/mount.log"
echo "loose objects in mirror: $before -> $(git -C "$W/thin.git" count-objects -v | awk '/^count/{print $2}')"
if [ -s "$W/ready" ]; then
  diff -rq --no-dereference --exclude=.git "$W/full" "$W/mnt" >"$W/diff.txt" || true; echo "only in source: $(grep -c "^Only in $W/full" "$W/diff.txt"); differing files: $(grep -c "^Files" "$W/diff.txt"); only in mount (empty build dirs): $(grep -c "^Only in $W/mnt" "$W/diff.txt")"
  git -C "$W/mnt" status --short --untracked-files=no >"$W/st.txt"; echo "git status lines (tracked): $(wc -l <"$W/st.txt")"
  fusermount3 -u "$W/mnt"; wait $MPID || true
fi
