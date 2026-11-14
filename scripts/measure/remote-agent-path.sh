#!/usr/bin/env bash
# What an agent on another machine feels through cmux Remote, against one enrolled daemon:
#   scripts/measure/remote-agent-path.sh BIN ROUTE STATE_DIR [n=20] [mib=64]
# BIN is a cmux with `remote exec` and `remote cp`; ROUTE the daemon's route (ws://HOST:PORT/); STATE_DIR
# the client state of a device the daemon already enrolled. Prints REMOTE-AGENT-PATH lines:
#   exec_cold_ms   p50/p95 of n `remote exec -- true` (a new link each: connect, Noise, open, spawn, exit)
#   exec_lines_ms  one exec printing 10000 lines (output streaming)
#   rtt_echo_ms    p50/p95 of n one-byte stdin -> stdout echoes through one live exec (a keystroke's echo)
#   cp_up_mibs / cp_down_mibs   one MIB MiB random file each way, sha256 checked
# Leaves nothing on the remote but its own temp files, which it removes.
set -euo pipefail
bin="$1" route="$2" state="$3" n="${4:-20}" mib="${5:-64}"
run() { "$bin" remote exec "$route" --state-dir "$state" "$@"; }
now_ms() { date +%s%3N; }
pct() { sort -n | awk -v p="$1" '{a[NR]=$1} END {i=int((NR-1)*p+0.5)+1; print a[i]}'; }

samples=()
for _ in $(seq 1 "$n"); do
  s=$(now_ms); run -- true; e=$(now_ms); samples+=($((e - s)))
done
printf '%s\n' "${samples[@]}" > /tmp/rap.cold
echo "REMOTE-AGENT-PATH exec_cold_ms p50=$(pct 0.5 < /tmp/rap.cold) p95=$(pct 0.95 < /tmp/rap.cold) n=$n"

s=$(now_ms); lines=$(run -- sh -c 'i=0; while [ $i -lt 10000 ]; do echo line$i; i=$((i+1)); done' | wc -l); e=$(now_ms)
echo "REMOTE-AGENT-PATH exec_lines_ms $((e - s)) lines=$lines"

# A keystroke's echo: one live `cat`, n single bytes written, each timed until it comes back.
fifo=$(mktemp -u); mkfifo "$fifo"
coproc ECHO { run -- cat < "$fifo"; }
exec 7> "$fifo"
: > /tmp/rap.rtt
for _ in $(seq 1 "$n"); do
  s=$(now_ms); printf 'k' >&7; IFS= read -r -n1 -u "${ECHO[0]}" _; e=$(now_ms); echo $((e - s)) >> /tmp/rap.rtt
done
exec 7>&-; rm -f "$fifo"; wait "$ECHO_PID" 2>/dev/null || true
echo "REMOTE-AGENT-PATH rtt_echo_ms p50=$(pct 0.5 < /tmp/rap.rtt) p95=$(pct 0.95 < /tmp/rap.rtt) n=$n"

local_file=$(mktemp); back=$(mktemp); remote="/tmp/rap-$$-$RANDOM"
head -c $((mib * 1048576)) /dev/urandom > "$local_file"
up=$("$bin" remote cp "$route" --state-dir "$state" --json "$local_file" "remote:$remote")
down=$("$bin" remote cp "$route" --state-dir "$state" --json "remote:$remote" "$back")
run -- rm -f "$remote"
[ "$(sha256sum < "$local_file")" = "$(sha256sum < "$back")" ] || { echo "REMOTE-AGENT-PATH cp sha256 mismatch"; exit 1; }
rm -f "$local_file" "$back"
echo "REMOTE-AGENT-PATH cp_up $up"
echo "REMOTE-AGENT-PATH cp_down $down"
