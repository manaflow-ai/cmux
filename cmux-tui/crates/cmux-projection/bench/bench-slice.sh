#!/usr/bin/env bash
# The first slice (RFD 0007): one machine reads a stand-in Mac folder through the projection, with
# no copy step, against today's way (rsync a copy, then work on it), both across the same modelled
# Mac-to-machine link (`slice_bench link`: RTT_MS round trip, MBPS cap each way).
#
# usage: nice -n 10 bench-slice.sh [RUNS]
# env:   RTT_MS (default 50), MBPS (default 400), ROOT (default ~/Projects/scratch/slice-bench),
#        BIN (slice_bench binary; default: built from this checkout), JOBS (default 16),
#        COPY_TIMEOUT (default 1800 s), OUT (default $ROOT/results.jsonl), ARMS=projected (skip the copy)
#
# The fixture is `git archive HEAD` of this checkout (the cmux repo: no .git, target/ or
# node_modules) in $ROOT/mac. Per run it appends one JSON line per arm to $OUT:
#   projected  mount_s, first_read_ms, warm_read_ms, warm_read_dropped_ms, ls_r_s (+ link bytes
#              across it), read20_ms, cargo_cold_s (in-tree target/, through the mount's upper),
#              cargo_warm_s (one blank line appended to wire.rs), cargo_cold_localtarget_s (second
#              fresh mount, CARGO_TARGET_DIR on local disk), bun_install_s, bun_build_s,
#              link_bytes_down, the mount's final stats, time_to_first_build_done_s
#   copy       copy_s (rsync through the link), then the same reads and builds on the copy
set -euo pipefail

RUNS=${1:-3}
RTT_MS=${RTT_MS:-50}
MBPS=${MBPS:-400}
ROOT=${ROOT:-$HOME/Projects/scratch/slice-bench}
JOBS=${JOBS:-16}
COPY_TIMEOUT=${COPY_TIMEOUT:-1800}
OUT=${OUT:-$ROOT/results.jsonl}
HERE=$(cd "$(dirname "$0")" && pwd)
CHECKOUT=$(git -C "$HERE" rev-parse --show-toplevel)
COMMIT=$(git -C "$CHECKOUT" rev-parse HEAD)
CARGO=${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}
P1=47101 P2=47102 P3=47103 P4=47104
FILE=cmux-tui/crates/cmux-projection/src/mount.rs
WIRE=crates/cmux-projection/src/wire.rs
BUN_DIR=cmux-tui/bindings/typescript
CRATE=cmux-projection
unset CARGO_TARGET_DIR RUSTC_WRAPPER

mkdir -p "$ROOT"
LOGS=$ROOT/logs
mkdir -p "$LOGS"
PIDS=()
MOUNTS=()

now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'; }
since_ms() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", (b - a) * 1000 }'; }
drop() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }
log() { echo "[$(date +%T)] $*" >&2; }
# A link's byte counts: "UP DOWN" (its stats file lags by up to 100 ms, so settle first).
link_bytes() {
  sleep 0.3
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["bytes_up"], d["bytes_down"])' "$1" 2>/dev/null || echo "0 0"
}
down_of() { link_bytes "$1" | cut -d' ' -f2; }
# A link's round trips so far: writes going up, one per ask.
asks_of() {
  sleep 0.3
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("writes_up", 0))' "$1" 2>/dev/null || echo 0
}
json_or_null() { if [ -n "$1" ]; then echo "$1"; else echo null; fi; }

cleanup() {
  set +e
  for at in "${MOUNTS[@]}"; do
    mountpoint -q "$at" && fusermount3 -u "$at" 2>/dev/null
  done
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

# --- setup ---------------------------------------------------------------------------------------
if [ -z "${BIN:-}" ]; then
  (cd "$CHECKOUT/cmux-tui" && "$CARGO" build -q --release -p cmux-projection --example slice_bench)
  BIN=$CHECKOUT/cmux-tui/target/release/examples/slice_bench
fi
if [ ! -f "$ROOT/mac/.fixture-$COMMIT" ]; then
  log "fixture: git archive $COMMIT into $ROOT/mac"
  rm -rf "$ROOT/mac"
  mkdir -p "$ROOT/mac"
  git -C "$CHECKOUT" archive "$COMMIT" | tar -x -C "$ROOT/mac"
  touch "$ROOT/mac/.fixture-$COMMIT"
fi
FIX_FILES=$(find "$ROOT/mac" -type f | wc -l)
FIX_BYTES=$(find "$ROOT/mac" -type f -printf '%s\n' | awk '{s+=$1} END {print s}')
log "fixture: $FIX_FILES files, $FIX_BYTES bytes"
# 20 files in one directory no other step reads.
READ20_DIR=$(cd "$ROOT/mac" && find . -path ./cmux-tui -prune -o -type f -size -64k -printf '%h\n' \
  | sort | uniq -c | awk '$1 >= 20 { print $2; exit }')
mapfile -t READ20 < <(cd "$ROOT/mac" && find "$READ20_DIR" -maxdepth 1 -type f -size -64k | sort | head -20)
log "read20: $READ20_DIR"
# Warm the registry (untimed) so neither arm pays downloads.
(cd "$ROOT/mac/cmux-tui" && "$CARGO" fetch -q) >"$LOGS/fetch.log" 2>&1

# The origin, the rsync daemon, and one modelled link in front of each.
"$BIN" serve "$ROOT/mac" "127.0.0.1:$P1" >"$LOGS/serve.out" 2>"$LOGS/serve.err" &
PIDS+=($!)
cat >"$ROOT/rsyncd.conf" <<EOF
use chroot = no
pid file = $ROOT/rsyncd.pid
log file = $LOGS/rsyncd.log
[mac]
  path = $ROOT/mac
  read only = yes
EOF
rsync --daemon --no-detach --config="$ROOT/rsyncd.conf" --port=$P3 --address=127.0.0.1 &
PIDS+=($!)
"$BIN" link "127.0.0.1:$P2" "127.0.0.1:$P1" --rtt-ms "$RTT_MS" --mbps "$MBPS" --stats "$ROOT/link-proj.json" 2>"$LOGS/link-proj.err" &
PIDS+=($!)
"$BIN" link "127.0.0.1:$P4" "127.0.0.1:$P3" --rtt-ms "$RTT_MS" --mbps "$MBPS" --stats "$ROOT/link-copy.json" 2>"$LOGS/link-copy.err" &
PIDS+=($!)
for _ in $(seq 600); do [ -s "$LOGS/serve.out" ] && break; sleep 0.1; done
SERVE_JSON=$(head -1 "$LOGS/serve.out")
log "serve: $SERVE_JSON"

# --- helpers -------------------------------------------------------------------------------------
read_ms() { local start; start=$(now); cat "$1" >/dev/null; since_ms "$start"; }
read20_ms() {
  local dir=$1 start; start=$(now)
  for f in "${READ20[@]}"; do cat "$dir/$f" >/dev/null; done
  since_ms "$start"
}
# cargo build, timed; prints "SECONDS COMPILING_LINES EXIT".
build() {
  local dir=$1 log=$2 start code=0
  start=$(now)
  (cd "$dir/cmux-tui" && "$CARGO" build -p "$CRATE" --offline -j "$JOBS") >"$log" 2>&1 || code=$?
  echo "$(since "$start") $(grep -cE '^ *Compiling ' "$log" || true) $code"
}
# bun install + build, timed; prints "INSTALL_S BUILD_S EXIT".
bun_arm() {
  local dir=$1/$BUN_DIR log=$2 start install code=0
  start=$(now)
  (cd "$dir" && bun install) >"$log" 2>&1 || code=$?
  install=$(since "$start")
  start=$(now)
  [ "$code" = 0 ] && { (cd "$dir" && bun run build) >>"$log" 2>&1 || code=$?; }
  echo "$install $(since "$start") $code"
}
# Starts a mount; sets MOUNT_PID and MOUNT_S (seconds from start to `mounted`).
start_mount() {
  local at=$1 state=$2 out=$3 start
  rm -rf "$state"; mkdir -p "$state" "$at"
  start=$(now)
  "$BIN" mount "127.0.0.1:$P2" "$at" "$state" >"$out" 2>"$out.err" &
  MOUNT_PID=$!
  PIDS+=("$MOUNT_PID")
  MOUNTS+=("$at")
  for _ in $(seq 6000); do
    grep -qx mounted "$out" 2>/dev/null && break
    kill -0 "$MOUNT_PID" 2>/dev/null || { log "mount died: $(cat "$out.err")"; return 1; }
    sleep 0.01
  done
  MOUNT_S=$(since "$start")
}
stop_mount() {
  local at=$1 pid=$2
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  mountpoint -q "$at" && fusermount3 -u "$at" 2>/dev/null || true
}

# --- arms ----------------------------------------------------------------------------------------
run_projected() {
  local run=$1 at=$ROOT/mnt-proj state=$ROOT/state-proj out=$LOGS/mount-$run.out
  local down0 mount_s first warm dropped ls_start ls_b0 ls_b1 ls_s ls_n r20 cold warmb bun down1
  down0=$(down_of "$ROOT/link-proj.json")
  local asks0 asks_c0 asks_c1 asks_l0 asks_l1
  asks0=$(asks_of "$ROOT/link-proj.json")
  drop
  log "projected $run: mount"
  start_mount "$at" "$state" "$out"
  mount_s=$MOUNT_S
  local mount_json; mount_json=$(head -1 "$out")
  first=$(read_ms "$at/$FILE")
  warm=$(read_ms "$at/$FILE")
  drop
  dropped=$(read_ms "$at/$FILE")
  ls_b0=$(down_of "$ROOT/link-proj.json")
  ls_start=$(now)
  ls_n=$(cd "$at" && find . | wc -l)
  ls_s=$(since "$ls_start")
  ls_b1=$(down_of "$ROOT/link-proj.json")
  r20=$(read20_ms "$at")
  log "projected $run: cargo cold"
  asks_c0=$(asks_of "$ROOT/link-proj.json")
  cold=$(build "$at" "$LOGS/cargo-proj-cold-$run.log")
  asks_c1=$(asks_of "$ROOT/link-proj.json")
  echo >>"$at/cmux-tui/$WIRE"
  log "projected $run: cargo warm"
  warmb=$(build "$at" "$LOGS/cargo-proj-warm-$run.log")
  log "projected $run: bun"
  bun=$(bun_arm "$at" "$LOGS/bun-proj-$run.log")
  stop_mount "$at" "$MOUNT_PID"
  local stats; stats=$(sed -n 3p "$out")
  # A second fresh mount: the same cold build with target/ on the machine's own disk.
  rm -rf "$ROOT/target-proj"
  drop
  log "projected $run: cargo cold, local target"
  start_mount "$at" "$ROOT/state-proj2" "$LOGS/mount2-$run.out"
  local cold_local
  asks_l0=$(asks_of "$ROOT/link-proj.json")
  cold_local=$(CARGO_TARGET_DIR=$ROOT/target-proj build "$at" "$LOGS/cargo-proj-localtarget-$run.log")
  asks_l1=$(asks_of "$ROOT/link-proj.json")
  stop_mount "$at" "$MOUNT_PID"
  local stats2; stats2=$(sed -n 3p "$LOGS/mount2-$run.out")
  down1=$(down_of "$ROOT/link-proj.json")
  read -r cold_s cold_n cold_rc <<<"$cold"
  read -r warm_s warm_n warm_rc <<<"$warmb"
  read -r local_s local_n local_rc <<<"$cold_local"
  read -r bun_i bun_b bun_rc <<<"$bun"
  python3 -I - "$OUT" <<EOF
import json, sys
mount = json.loads('''$mount_json''' or 'null')
stats = json.loads('''$stats''' or 'null')
stats2 = json.loads('''$stats2''' or 'null')
row = dict(arm="projected", run=$run, load1=float(open("/proc/loadavg").read().split()[0]), rtt_ms=$RTT_MS, mbps=$MBPS, commit="$COMMIT",
  fixture_files=$FIX_FILES, fixture_bytes=$FIX_BYTES, serve=json.loads('''$SERVE_JSON'''),
  mount_s=$mount_s, mount=mount, first_read_ms=$first, warm_read_ms=$warm,
  warm_read_dropped_ms=$dropped, ls_r_s=$ls_s, ls_r_entries=$ls_n, ls_r_link_bytes_down=$ls_b1 - $ls_b0,
  read20_ms=$r20, cargo_cold_s=$cold_s, cargo_cold_compiling=$cold_n, cargo_cold_exit=$cold_rc,
  cargo_warm_s=$warm_s, cargo_warm_compiling=$warm_n, cargo_warm_exit=$warm_rc,
  cargo_cold_localtarget_s=$local_s, cargo_cold_localtarget_compiling=$local_n,
  cargo_cold_localtarget_exit=$local_rc, bun_install_s=$bun_i, bun_build_s=$bun_b, bun_exit=$bun_rc,
  link_bytes_down=$down1 - $down0, link_asks=$asks_l1 - $asks0,
  cargo_cold_asks=$asks_c1 - $asks_c0, cargo_cold_localtarget_asks=$asks_l1 - $asks_l0, stats=stats, stats_localtarget_mount=stats2,
  fetched_files=stats and stats["remote_reads"], fetched_bytes=stats and stats["remote_bytes"],
  time_to_first_build_done_s=round($mount_s + $cold_s, 3))
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
print(json.dumps(row))
EOF
}

run_copy() {
  local run=$1 dest=$ROOT/copy
  local b0 b1 start copy_s="" timed_out=false first warm dropped ls_start ls_s ls_n r20 cold warmb bun
  rm -rf "$dest"
  drop
  b0=$(down_of "$ROOT/link-copy.json")
  log "copy $run: rsync"
  start=$(now)
  if timeout "$COPY_TIMEOUT" rsync -a "rsync://127.0.0.1:$P4/mac/" "$dest/" 2>"$LOGS/rsync-$run.err"; then
    copy_s=$(since "$start")
  else
    timed_out=true
  fi
  b1=$(down_of "$ROOT/link-copy.json")
  local cold_s=null warm_s=null bun_i=null bun_b=null first=null warm=null dropped=null ls_s=null ls_n=null r20=null
  local cold_n=null warm_n=null cold_rc=null warm_rc=null bun_rc=null
  if [ "$timed_out" = false ]; then
    drop
    first=$(read_ms "$dest/$FILE")
    warm=$(read_ms "$dest/$FILE")
    drop
    dropped=$(read_ms "$dest/$FILE")
    ls_start=$(now)
    ls_n=$(cd "$dest" && find . | wc -l)
    ls_s=$(since "$ls_start")
    r20=$(read20_ms "$dest")
    log "copy $run: cargo cold"
    cold=$(build "$dest" "$LOGS/cargo-copy-cold-$run.log")
    echo >>"$dest/cmux-tui/$WIRE"
    log "copy $run: cargo warm"
    warmb=$(build "$dest" "$LOGS/cargo-copy-warm-$run.log")
    log "copy $run: bun"
    bun=$(bun_arm "$dest" "$LOGS/bun-copy-$run.log")
    read -r cold_s cold_n cold_rc <<<"$cold"
    read -r warm_s warm_n warm_rc <<<"$warmb"
    read -r bun_i bun_b bun_rc <<<"$bun"
  fi
  python3 -I - "$OUT" <<EOF
import json, sys
copy_s = $(json_or_null "$copy_s")
cold_s = $cold_s
row = dict(arm="copy", run=$run, load1=float(open("/proc/loadavg").read().split()[0]), rtt_ms=$RTT_MS, mbps=$MBPS, commit="$COMMIT",
  fixture_files=$FIX_FILES, fixture_bytes=$FIX_BYTES, copy_s=copy_s,
  copy_timed_out=$([ "$timed_out" = true ] && echo True || echo False), copy_link_bytes_down=$b1 - $b0,
  first_read_ms=$first, warm_read_ms=$warm, warm_read_dropped_ms=$dropped, ls_r_s=$ls_s,
  ls_r_entries=$ls_n, read20_ms=$r20, cargo_cold_s=cold_s, cargo_cold_compiling=$cold_n,
  cargo_cold_exit=$cold_rc, cargo_warm_s=$warm_s, cargo_warm_compiling=$warm_n,
  cargo_warm_exit=$warm_rc, bun_install_s=$bun_i, bun_build_s=$bun_b, bun_exit=$bun_rc,
  link_bytes_down=$b1 - $b0,
  time_to_first_build_done_s=None if copy_s is None or cold_s is None else round(copy_s + cold_s, 3))
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
print(json.dumps(row))
EOF
  rm -rf "$dest"
}

for run in $(seq 1 "$RUNS"); do
  run_projected "$run"
  [ "${ARMS:-both}" = projected ] || run_copy "$run"
done
rm -rf "$ROOT/state-proj" "$ROOT/state-proj2" "$ROOT/target-proj"
log "done: $OUT"
