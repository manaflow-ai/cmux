#!/usr/bin/env bash
# One harness for both arms of hq#13177 step 6: today's lane checkout (`wt new --at`) against a
# projected checkout (`cmux-projection git-mount`) of the same commit, on one lane VM.
#
# usage: bench-checkout.sh RUNS [ARMS...]       (ARMS default: wt projected)
# env:   COMMIT (default f0143931...), CRATE (default cmux-tui-core), BIN (cmux-projection binary)
#
# Per run and arm it records, as one JSON line in $OUT:
#   checkout_s   wall time from start to a usable tree (cmux-tui/Cargo.toml readable, `ls` works)
#   disk_kb      df delta of / across the checkout (used blocks, not du)
#   status_s     `git status --porcelain` right after the checkout, and its line count
#   cold_s       first `cargo check -p $CRATE` with an empty target dir (registry already fetched)
#   build_kb     df delta across that build
#   warm_s       `cargo check -p $CRATE` after a fresh second checkout at the same commit and path,
#                keeping the target dir, and how many crates it rebuilt
set -euo pipefail

RUNS=${1:-3}; shift || true
ARMS=("${@:-wt projected}")
[ ${#ARMS[@]} -eq 1 ] && read -r -a ARMS <<<"${ARMS[0]}"
COMMIT=${COMMIT:-f014393162ebfac32e3c3e6dd09497008d19af34}
CRATE=${CRATE:-cmux-tui-core}
MIRROR=${MIRROR:-$HOME/Projects/.wt-mirrors/manaflow-ai/cmux.git}
BIN=${BIN:-$HOME/scratch/projbuild/target/release/cmux-projection}
ROOT=${ROOT:-$HOME/scratch/pbench}
OUT=${OUT:-$ROOT/results.jsonl}
JOBS=${JOBS:-8}
WT_NAME=pbench-wt
MNT=$ROOT/mnt
KEEP=$ROOT/keep
mkdir -p "$ROOT"

now() { date +%s.%N; }
used_kb() { df --output=used / | tail -1 | tr -d ' '; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'; }

# cargo check, timed; prints "SECONDS CRATES_REBUILT".
check() {
  local dir=$1 log=$ROOT/cargo.log start
  start=$(now)
  (cd "$dir/cmux-tui" && nice -n 10 cargo check --offline -j "$JOBS" -p "$CRATE" >"$log" 2>&1)
  echo "$(since "$start") $(grep -cE '^ *(Compiling|Checking) ' "$log" || true)"
}

status() {
  local dir=$1 start lines
  start=$(now)
  lines=$(git -C "$dir" status --porcelain | wc -l)
  echo "$(since "$start") $lines"
}

# --- wt: today's lane checkout -------------------------------------------------------------
wt_checkout() { wt new manaflow-ai/cmux --at "$COMMIT" --name "$WT_NAME" 2>/dev/null | tail -1; }
wt_remove() { git --git-dir "$MIRROR" worktree remove --force "$1" 2>/dev/null || true; }

run_wt() {
  local run=$1 before start dir st cold after warm
  dir=$(cat "$ROOT/wt-path" 2>/dev/null || true)
  if [ -n "$dir" ] && [ -d "$dir" ]; then wt_remove "$dir"; fi
  before=$(used_kb); start=$(now)
  dir=$(wt_checkout)
  echo "$dir" >"$ROOT/wt-path"
  test -f "$dir/cmux-tui/Cargo.toml" && ls "$dir" >/dev/null
  local checkout_s; checkout_s=$(since "$start"); local disk_kb=$(( $(used_kb) - before ))
  st=$(status "$dir")
  before=$(used_kb); cold=$(check "$dir"); local build_kb=$(( $(used_kb) - before ))
  # A fresh second checkout at the same commit and path, keeping target/.
  mv "$dir/cmux-tui/target" "$ROOT/wt-target"
  wt_remove "$dir"
  dir=$(wt_checkout)
  mv "$ROOT/wt-target" "$dir/cmux-tui/target"
  warm=$(check "$dir")
  rm -rf "$dir/cmux-tui/target"
  wt_remove "$dir"
  record wt "$run" "$checkout_s" "$disk_kb" "$st" "$cold" "$build_kb" "$warm"
}

# --- projected: cmux-projection git-mount ------------------------------------------------------
mount_proj() {
  local ready=$ROOT/ready
  rm -f "$ready"
  "$BIN" git-mount --git-dir "$MIRROR" --commit "$COMMIT" --at "$MNT" --keep "$KEEP" --fresh \
    --name pbench-projected --ready-file "$ready" 2>>"$ROOT/mount.log" &
  echo $! >"$ROOT/mount.pid"
  until [ -s "$ready" ]; do
    kill -0 "$(cat "$ROOT/mount.pid")" 2>/dev/null || { echo "mount died" >&2; tail -5 "$ROOT/mount.log" >&2; exit 1; }
    sleep 0.005
  done
}
unmount_proj() {
  fusermount3 -u "$MNT" 2>/dev/null || true
  wait "$(cat "$ROOT/mount.pid" 2>/dev/null)" 2>/dev/null || true
}

run_projected() {
  local run=$1 before start st cold warm
  unmount_proj
  rm -rf "$KEEP" "$MIRROR/worktrees/pbench-projected"
  before=$(used_kb); start=$(now)
  mount_proj
  test -f "$MNT/cmux-tui/Cargo.toml" && ls "$MNT" >/dev/null
  local checkout_s; checkout_s=$(since "$start"); local disk_kb=$(( $(used_kb) - before ))
  cp "$ROOT/ready" "$ROOT/ready-run$run.json"
  st=$(status "$MNT")
  before=$(used_kb); cold=$(check "$MNT"); local build_kb=$(( $(used_kb) - before ))
  # A fresh second checkout at the same commit and path: a new upper and index, same keep folder.
  unmount_proj
  mount_proj
  warm=$(check "$MNT")
  unmount_proj
  rm -rf "$KEEP" "$MIRROR/worktrees/pbench-projected"
  record projected "$run" "$checkout_s" "$disk_kb" "$st" "$cold" "$build_kb" "$warm"
}

record() {
  local arm=$1 run=$2 checkout_s=$3 disk_kb=$4 st=$5 cold=$6 build_kb=$7 warm=$8
  local line
  line=$(printf '{"arm":"%s","run":%s,"host":"%s","commit":"%s","crate":"%s","checkout_s":%s,"disk_kb":%s,"status_s":%s,"status_lines":%s,"cold_s":%s,"cold_crates":%s,"build_kb":%s,"warm_s":%s,"warm_crates":%s}' \
    "$arm" "$run" "$(hostname)" "$COMMIT" "$CRATE" "$checkout_s" "$disk_kb" ${st% *} ${st#* } ${cold% *} ${cold#* } "$build_kb" ${warm% *} ${warm#* })
  echo "$line" | tee -a "$OUT"
}

# --- setup, untimed and the same for both arms --------------------------------------------
# The mirror is a blob:none partial clone: fetch the commit's missing blobs once, so neither arm
# pays for them, then fetch the crate's registry dependencies.
missing=$(git --git-dir "$MIRROR" rev-list --objects --no-walk --missing=print "$COMMIT" | sed -n 's/^?//p')
if [ -n "$missing" ]; then
  echo "$missing" | git --git-dir "$MIRROR" -c fetch.negotiationAlgorithm=noop fetch origin --no-tags \
    --no-write-fetch-head --recurse-submodules=no --filter=blob:none --stdin
fi
setup=$(wt_checkout)
(cd "$setup/cmux-tui" && cargo fetch >/dev/null 2>&1)
wt_remove "$setup"

for run in $(seq 1 "$RUNS"); do
  for arm in "${ARMS[@]}"; do
    "run_$arm" "$run"
  done
done
