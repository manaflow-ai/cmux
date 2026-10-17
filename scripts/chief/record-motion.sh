#!/usr/bin/env bash
# Records Chief Home's send morph (1 and 2 lines), receipts, typing and an
# incoming message from a running tagged DEBUG app with the scripted brain,
# through `cmux record` (permission-free, cmux windows only), then splits
# each clip into labeled frames with the verify-ui-video splitter.
#
# Usage:
#   CMUX_TAG=<tag> scripts/chief/record-motion.sh [--out <dir>] [--fps <1-30>]
#
# The tagged app must run with CMUX_CHIEF_BRAIN=scripted (see
# .chief-work/motion-proof.md: reload.sh does not pass it through yet).
# `cmux record` caps --fps at 30; 60 fps evidence comes from the
# MessagesLabHomeTests golden harness, not from these clips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${CMUX_TAG:?CMUX_TAG is required}"
OUT="${TMPDIR:-/tmp}/chief-motion-${CMUX_TAG}"
FPS=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
SPLIT="${CMUX_VERIFY_UI_VIDEO_SPLIT:-$HOME/manaflow/cmuxterm-hq/skills/debug/verify-ui-video/scripts/split-ui-video-frames.sh}"
mkdir -p "$OUT"

cli() { "$ROOT/scripts/cmux-debug-cli.sh" "$@"; }

json_field() { python3 -I -c 'import json,sys; v=json.load(sys.stdin); print(json.dumps(v.get(sys.argv[1])))' "$1"; }

working_count() { cli chief status --json | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin).get("working") or []))'; }

# Bounded poll of the socket's working set (state, not elapsed time): waits
# until the turn is running ("busy") or has ended ("idle"), or fails at the deadline.
wait_working() {
  local want="$1" deadline=$((SECONDS + ${2:-20})) n
  while (( SECONDS < deadline )); do
    n="$(working_count)"
    if [[ "$want" == busy && "$n" -gt 0 ]] || [[ "$want" == idle && "$n" -eq 0 ]]; then return 0; fi
    sleep 0.1 # poll interval of a state check with a deadline, not synchronization by time
  done
  echo "timed out waiting for Chief to be $want" >&2
  return 1
}

# record <name> <max-seconds> <command...>: one clip around one interaction.
record() {
  local name="$1" seconds="$2"; shift 2
  local clip="$OUT/$name.mp4"
  rm -f "$clip"
  wait_working idle
  local id
  id="$(cli record start --fps "$FPS" --max-seconds "$seconds" --label "chief-$name" --out "$clip" --json | json_field id | tr -d '"')"
  cli record note "$name" >/dev/null
  "$@"
  wait_working busy 10
  wait_working idle 30
  # A clip that already reached --max-seconds stopped itself; read its status instead.
  cli record stop --id "$id" --json > "$OUT/$name.record.json" 2>/dev/null \
    || cli record status --id "$id" --json > "$OUT/$name.record.json"
  "$SPLIT" --video "$clip" --out "$OUT/$name" --start 0 --duration "$seconds" --fps "$FPS" \
    --label "chief $name" --cols 10 \
    --success-criteria "bubble morphs out of the field in one spring; receipts and typing settle without a jump or a blank frame"
}

send_draft() {
  cli chief debug set-draft --text "$1" >/dev/null
  cli chief debug send-draft >/dev/null
}

cli chief open >/dev/null
cli chief status --json > "$OUT/status-before.json"

# 1. Send morph (1 line) -> delivered -> read -> typing -> reply.
record send-1line 12 send_draft "What are my agents doing?"
# 2. Send morph (2 lines, field shrink) -> same tail.
record send-2line 12 send_draft $'Check the build\nand tell me when it is green'
# 3. Receive: an agent report arrives, Chief types and replies.
record receive 12 cli chief send --from "build bot" "Release build finished"

cli chief debug rows > "$OUT/rows-after.json"
echo "$OUT"
