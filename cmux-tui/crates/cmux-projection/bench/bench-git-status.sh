#!/usr/bin/env bash
# `git status` on a projected git repo (RFD 0007, hard case 2): the cold first one on a fresh mount and
# the warm one after, across the modelled Mac-to-machine link (`slice_bench link`, RTT_MS round trip).
#
# usage: bench-git-status.sh MAC_FOLDER REPO [RUNS]
#   MAC_FOLDER  the stand-in Mac folder that is projected (its repos' indexes fresh: run `git status`
#               in each on the "Mac" first)
#   REPO        the repo to run `git status` in, relative to MAC_FOLDER
# env: RTT_MS (default 50), MBPS (default 400), ROOT (default ~/Projects/scratch/git-status-bench),
#      BIN (slice_bench binary; default: built from this checkout), HOOK (the cmux-projection
#      binary; default: built beside it), FSMONITOR=0 (leave git's fsmonitor off and the mount
#      without its git warm-up: the before arm), OUT (default $ROOT/results.jsonl)
#
# Git runs with the machine image's settings (core.checkStat=minimal, core.trustctime=false), as
# the daemon's `git-stat.config` sets them; with FSMONITOR=1 `core.fsmonitor` is the projection's
# hook too, and the timed status starts once the mount says its git warm-up is done (it runs while
# the agent's first model turn does; its own time is `ready_ms`). Each run appends one JSON line:
#   {fsmonitor, files, cold_s, warm_s, cold_asks, cold_link_bytes_down, edit_s, status_lines, ready_ms}
# where edit_s is a `git status` after one tracked file is edited and one untracked file made.
set -euo pipefail

MAC=$(cd "$1" && pwd)
[ -z "${BIN:-}" ] || BIN=$(realpath "$BIN")
[ -z "${HOOK:-}" ] || HOOK=$(realpath "$HOOK")
REPO=$2
RUNS=${3:-3}
RTT_MS=${RTT_MS:-50}
MBPS=${MBPS:-400}
ROOT=${ROOT:-$HOME/Projects/scratch/git-status-bench}
OUT=${OUT:-$ROOT/results.jsonl}
FSMONITOR=${FSMONITOR:-1}
HERE=$(cd "$(dirname "$0")" && pwd)
CHECKOUT=$(git -C "$HERE" rev-parse --show-toplevel)
CARGO=${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}
P1=${P1:-47201} P2=${P2:-47202}
unset RUSTC_WRAPPER

mkdir -p "$ROOT/logs"
PIDS=()
mount_pid=
cleanup() {
  set +e
  [ -n "$mount_pid" ] && kill "$mount_pid" 2>/dev/null
  mountpoint -q "$ROOT/mnt" && fusermount3 -u "$ROOT/mnt" 2>/dev/null
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }'; }
stat_of() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], 0))' "$1" "$2" 2>/dev/null || echo 0; }

if [ -z "${BIN:-}" ]; then
  (cd "$CHECKOUT/cmux-tui" && "$CARGO" build -q --release -p cmux-projection --example slice_bench --bin cmux-projection)
  BIN=$CHECKOUT/cmux-tui/target/release/examples/slice_bench
fi
HOOK=${HOOK:-$(dirname "$(dirname "$BIN")")/cmux-projection}
FILES=$(git -C "$MAC/$REPO" ls-files | wc -l)

"$BIN" serve "$MAC" "127.0.0.1:$P1" >"$ROOT/logs/serve.out" 2>"$ROOT/logs/serve.err" &
PIDS+=($!)
"$BIN" link "127.0.0.1:$P2" "127.0.0.1:$P1" --rtt-ms "$RTT_MS" --mbps "$MBPS" --stats "$ROOT/link.json" 2>"$ROOT/logs/link.err" &
PIDS+=($!)
for _ in $(seq 600); do [ -s "$ROOT/logs/serve.out" ] && break; sleep 0.1; done

GIT=(git -c core.checkStat=minimal -c core.trustctime=false)
if [ "$FSMONITOR" = 1 ]; then
  GIT+=(-c fsmonitor.allowRemote=true -c "core.fsmonitor='$HOOK' fsmonitor-hook '$ROOT/state/fsmonitor.sock' '$ROOT/mnt'")
fi
for run in $(seq "$RUNS"); do
  rm -rf "$ROOT/state"
  mkdir -p "$ROOT/mnt" "$ROOT/state"
  out=$ROOT/logs/mount-$run.out
  : >"$out"
  env ${FSMONITOR:+SLICE_FSMONITOR="$FSMONITOR"} "$BIN" mount "127.0.0.1:$P2" "$ROOT/mnt" "$ROOT/state" >"$out" 2>"$out.err" &
  mount_pid=$!
  for _ in $(seq 600); do grep -qx mounted "$out" 2>/dev/null && break; sleep 0.1; done
  grep -qx mounted "$out" || { echo "mount failed: $(cat "$out.err")" >&2; exit 1; }
  # What the mount does before the agent's first command (the bench's own wait, as a model turn).
  if [ "$FSMONITOR" = 1 ]; then
    for _ in $(seq 300); do grep -q '"fsmonitor_ready"' "$out" && break; sleep 0.05; done
  fi
  ready_ms=$(python3 -I -c 'import json,sys
for line in open(sys.argv[1]):
    if "fsmonitor_ready" in line: print(json.loads(line)["ready_ms"]); break
else: print(0)' "$out")
  sleep 0.3
  asks0=$(stat_of "$ROOT/link.json" writes_up); down0=$(stat_of "$ROOT/link.json" bytes_down)
  cd "$ROOT/mnt/$REPO"
  t=$(now); lines=$("${GIT[@]}" status --porcelain | wc -l); cold=$(since "$t")
  sleep 0.3
  asks1=$(stat_of "$ROOT/link.json" writes_up); down1=$(stat_of "$ROOT/link.json" bytes_down)
  t=$(now); "${GIT[@]}" status --porcelain >/dev/null; warm=$(since "$t")
  tracked=$(git ls-files -z -- '*.md' | tr '\0' '\n' | sed -n 1p)
  echo "bench edit" >>"$tracked"
  echo new >bench-untracked-file
  t=$(now); edit_lines=$("${GIT[@]}" status --porcelain | wc -l); edit=$(since "$t")
  cd "$ROOT"
  kill "$mount_pid"; wait "$mount_pid" 2>/dev/null || true
  mountpoint -q "$ROOT/mnt" && fusermount3 -u "$ROOT/mnt"
  line="{\"fsmonitor\":$FSMONITOR,\"rtt_ms\":$RTT_MS,\"files\":$FILES,\"cold_s\":$cold,\"warm_s\":$warm,\"cold_asks\":$((asks1 - asks0)),\"cold_link_bytes_down\":$((down1 - down0)),\"status_lines\":$lines,\"edit_s\":$edit,\"edit_status_lines\":$edit_lines,\"ready_ms\":$ready_ms}"
  echo "$line" | tee -a "$OUT"
done
