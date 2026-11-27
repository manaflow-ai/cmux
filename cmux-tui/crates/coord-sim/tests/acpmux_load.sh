#!/usr/bin/env bash
# Does a real acpmux daemon open what `coord-sim gen` writes? Builds acpmux and coord-sim (release),
# generates chats into a scratch home, starts `acpmux daemon run` on it, and reads each chat back:
# the list, the newest records (`session tail`), every turn (`session history`, a whole-log read) and a
# search over its messages. Prints one JSON line per chat with the times; exits non-zero on any failure.
#
#   tests/acpmux_load.sh [SPEC...]     SPEC is NAME:GEN-FLAGS, e.g. "100k:--events 100000"
#
# Default: a 100k-event chat, a 1 GB chat and a 2 GB chat. Run from the repo root; on a lane VM through
# `cmux-ci test --setup rust -- bash cmux-tui/crates/coord-sim/tests/acpmux_load.sh`.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/coord-sim-load.XXXXXX")
DAEMON=""
cleanup() {
  if [ -n "$DAEMON" ]; then kill "$DAEMON" 2>/dev/null || true; wait "$DAEMON" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ $# -eq 0 ]; then
  set -- "100k:--seed 1 --events 100000 --harness claude" \
         "1gb:--seed 1 --target-bytes 1GB --harness claude" \
         "2gb:--seed 2 --target-bytes 2GB --scale 6 --harness claude"
fi

ms() { date +%s%3N; }
# Where cargo puts a workspace's builds (CARGO_TARGET_DIR or build.target-dir move it off ./target on CI).
target_dir() { (cd "$1" && cargo metadata --format-version 1 --no-deps | grep -o '"target_directory":"[^"]*"' | cut -d'"' -f4); }

t0=$(ms)
# ACPMUX_BIN / COORD_SIM_BIN: binaries already built (nothing is built then).
ACPMUX=${ACPMUX_BIN:-}
SIM=${COORD_SIM_BIN:-}
if [ -z "$ACPMUX" ]; then
  (cd "$ROOT/cmux-tui" && cargo build --release -q -p acpmux --bin acpmux)
  ACPMUX="$(target_dir "$ROOT/cmux-tui")/release/acpmux"
fi
if [ -z "$SIM" ]; then
  (cd "$ROOT/cmux-tui/crates/coord-sim" && cargo build --release -q)
  SIM="$(target_dir "$ROOT/cmux-tui/crates/coord-sim")/release/coord-sim"
fi
echo "{\"step\":\"build\",\"ms\":$(( $(ms) - t0 )),\"acpmux\":\"$("$ACPMUX" --version 2>&1 | head -1)\"}"

fail=0
for spec in "$@"; do
  name=${spec%%:*}
  flags=${spec#*:}
  out="$WORK/$name"
  # shellcheck disable=SC2086
  gen=$("$SIM" gen --out "$out" --format acpmux $flags)
  echo "{\"step\":\"gen\",\"chat\":\"$name\",\"run\":$gen}"
  home="$out/acpmux-home"
  export HOME="$out" ACPMUX_HOME="$home"
  unset ACPMUX_SOCKET
  chat=$(sed -n 's/.*"name": "\(coord-sim-[^"]*\)".*/\1/p' "$out/manifest.json" | head -1)
  lines=$(sed -n 's/.*"lines": \([0-9]*\).*/\1/p' "$out/manifest.json" | head -1)
  bytes=$(sed -n 's/.*"bytes": \([0-9]*\).*/\1/p' "$out/manifest.json" | head -1)

  start=$(ms)
  NO_COLOR=1 "$ACPMUX" daemon run --log info >"$WORK/$name.log" 2>&1 &
  DAEMON=$!
  # The daemon logs one line once every chat's log is read (`hub/log_load.rs`).
  loaded=""
  for _ in $(seq 1 1200); do
    if grep -q "loaded the chat logs of" "$WORK/$name.log"; then loaded=$(ms); break; fi
    if ! kill -0 "$DAEMON" 2>/dev/null; then break; fi
    sleep 0.5
  done
  if [ -z "$loaded" ]; then
    echo "{\"chat\":\"$name\",\"ok\":false,\"error\":\"the daemon never read the logs\"}"
    tail -40 "$WORK/$name.log"
    fail=1
    kill "$DAEMON" 2>/dev/null || true; wait "$DAEMON" 2>/dev/null || true; DAEMON=""
    continue
  fi
  sleep 0.2
  load_line=$(grep -o "loaded the chat logs of [0-9]* sessions in [0-9]* ms" "$WORK/$name.log" | head -1 || true)
  load_ms=$(echo "$load_line" | sed -n "s/.* in \([0-9]*\) ms/\1/p")

  ok=true
  a=$(ms); listed=$("$ACPMUX" ls --json 2>&1) || ok=false; ls_ms=$(( $(ms) - a ))
  echo "$listed" | grep -q "\"$chat\"" || { ok=false; echo "ls does not list $chat: ${listed:0:400}"; }
  a=$(ms); tail_out=$("$ACPMUX" session tail "$chat" --last 500 2>&1) || { ok=false; echo "tail: ${tail_out:0:400}"; }; tail_ms=$(( $(ms) - a ))
  tail_n=$(printf '%s\n' "$tail_out" | wc -l)
  a=$(ms); hist=$("$ACPMUX" session history "$chat" -n 100000 2>&1) || { ok=false; echo "history: ${hist:0:400}"; }; hist_ms=$(( $(ms) - a ))
  turns=$(printf '%s\n' "$hist" | wc -l)
  a=$(ms); found=$("$ACPMUX" session search "$chat" alpha build 2>&1) || { ok=false; echo "search: ${found:0:400}"; }; search_ms=$(( $(ms) - a ))
  hits=$(printf '%s\n' "$found" | wc -l)
  errors=$(grep -c " ERROR " "$WORK/$name.log" || true)
  if [ "$errors" != "0" ]; then grep " ERROR " "$WORK/$name.log" | head -10; fi
  rss_kb=$(awk '/VmHWM/{print $2}' "/proc/$DAEMON/status" 2>/dev/null || echo 0)
  echo "{\"chat\":\"$name\",\"ok\":$ok,\"lines\":$lines,\"bytes\":$bytes,\"daemon_start_to_logs_read_ms\":$(( loaded - start )),\"load_logs_ms\":${load_ms:-null},\"ls_ms\":$ls_ms,\"tail_ms\":$tail_ms,\"tail_lines\":$tail_n,\"history_ms\":$hist_ms,\"history_lines\":$turns,\"search_ms\":$search_ms,\"search_lines\":$hits,\"daemon_errors\":$errors,\"daemon_peak_rss_kb\":${rss_kb:-0}}"
  printf '%s\n' "$hist" | tail -3
  [ "$ok" = true ] || fail=1
  "$ACPMUX" daemon stop >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do kill -0 "$DAEMON" 2>/dev/null || break; sleep 0.5; done
  kill "$DAEMON" 2>/dev/null || true; wait "$DAEMON" 2>/dev/null || true; DAEMON=""
  rm -rf "$out" 2>/dev/null || true
done
exit $fail
