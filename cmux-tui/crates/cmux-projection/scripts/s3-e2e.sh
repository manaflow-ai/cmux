#!/usr/bin/env bash
# usage: s3-e2e.sh CMUX_PROJECTION_BIN SOURCE_DIR   (Linux, FUSE)
# End to end: rclone's S3 server (SigV4 auth on) as the bucket; push a repo's blobs with
# `cmux-projection s3-push`; a blobless mirror fills them through the chain's S3 tier, with its
# git remote pointed nowhere, so a blob the bucket misses fails the mount instead of fetching.
set -euo pipefail
BIN=$(realpath "${1:?cmux-projection binary}")
SRC=${2:?a folder to commit as the test repo}
W=$(mktemp -d /tmp/s3-e2e.XXXXXX); mkdir -p "$W/data/blobs"
RCLONE=${RCLONE:-rclone}  # rclone >= 1.65 (serve s3)
PORT=$((19000 + RANDOM % 1000))
"$RCLONE" serve s3 --auth-key AKIDE2E,e2e-secret-key --addr "127.0.0.1:$PORT" "$W/data" >"$W/rclone.log" 2>&1 &
RPID=$!
MPID=
cleanup() {
  if [ -n "$MPID" ]; then fusermount3 -u "$W/mnt" 2>/dev/null || true; wait "$MPID" 2>/dev/null || true; fi
  kill "$RPID" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# The test repo: a full store, then a blobless bare clone of it (what a wt mirror is).
git init -q "$W/full"; tar -C "$SRC" --exclude=.git -cf - . | tar -C "$W/full" -xf -
git -C "$W/full" add -A
git -C "$W/full" -c user.name=e2e -c user.email=e2e@local commit -qm e2e
git -C "$W/full" config uploadpack.allowFilter true
COMMIT=$(git -C "$W/full" rev-parse HEAD)
git clone -q --bare --filter=blob:none "file://$W/full" "$W/thin.git"
echo "repo: $(git -C "$W/full" ls-tree -r HEAD | wc -l) files, $(du -sh --exclude=.git "$W/full" | cut -f1)"

# The chain reads the bucket from these; s3-push writes to the same base with the same keys.
export CMUX_PROJECTION_S3_ENDPOINT=http://127.0.0.1:$PORT CMUX_PROJECTION_S3_BUCKET=blobs
export CMUX_PROJECTION_S3_PREFIX=objects CMUX_PROJECTION_S3_REGION=us-east-1
# Every key sits under the tenant; rclone's server keeps no SSE, so the PUTs do not ask for it.
export CMUX_PROJECTION_S3_TENANT=e2e CMUX_PROJECTION_S3_SSE=off
BASE=$CMUX_PROJECTION_S3_ENDPOINT/blobs/objects/e2e
echo "--- wrong key is refused"
if AWS_ACCESS_KEY_ID=AKIDE2E AWS_SECRET_ACCESS_KEY=wrong "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD; then
  echo "FAIL: a wrong key pushed"; exit 1
fi
export AWS_ACCESS_KEY_ID=AKIDE2E AWS_SECRET_ACCESS_KEY=e2e-secret-key
echo "--- push"; "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD
echo "--- push again (the bucket holds them)"; "$BIN" s3-push --git-dir "$W/full/.git" --to "$BASE" --commit HEAD

echo "--- blobless mirror fills from the bucket (no peers, no git fetch source)"
before=$(git -C "$W/thin.git" count-objects -v | awk '/^count/{print $2}')
git -C "$W/thin.git" remote set-url origin "file:///nonexistent"
mkdir -p "$W/mnt"
start=$(date +%s%N)
"$BIN" git-mount --git-dir "$W/thin.git" --commit "$COMMIT" --at "$W/mnt" --keep "$W/keep" --ready-file "$W/ready" >"$W/mount.log" 2>&1 &
MPID=$!
for _ in $(seq 600); do [ -s "$W/ready" ] && break; kill -0 "$MPID" 2>/dev/null || break; sleep 0.1; done
echo "wall to ready: $(( ($(date +%s%N) - start) / 1000000 )) ms"
grep -E "missing blobs|total_ms|error" "$W/mount.log" || cat "$W/mount.log"
echo "loose objects in mirror: $before -> $(git -C "$W/thin.git" count-objects -v | awk '/^count/{print $2}')"
[ -s "$W/ready" ] || { echo "FAIL: the mount never came up"; exit 1; }
diff -rq --no-dereference --exclude=.git "$W/full" "$W/mnt" >"$W/diff.txt" || true
only=$(grep -c "^Only in $W/full" "$W/diff.txt" || true); differ=$(grep -c "^Files" "$W/diff.txt" || true)
echo "only in source: $only; differing files: $differ"
git -C "$W/mnt" status --short --untracked-files=no >"$W/st.txt"
echo "git status lines (tracked): $(wc -l <"$W/st.txt")"
[ "$only" = 0 ] && [ "$differ" = 0 ] && [ ! -s "$W/st.txt" ] || { echo FAIL; exit 1; }
echo PASS
