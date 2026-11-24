#!/bin/bash
# The locked-screen experiment inside the guest's login session (macos-locked-screen-cu.sh starts it
# as a LaunchAgent, so it runs in the console user's Aqua session). Writes $D/out/results.jsonl, one
# JSON line per check, and PNGs to $D/out. Rounds, each against TextEdit with a note open:
#   A-unlocked           the baseline;
#   A2-unlocked-virtual  TextEdit's window moved onto a CGVirtualDisplay this run holds (no
#                        display-sleep assertion, so round C can find the displays asleep);
#   B-locked             right after SACLockScreenImmediate;
#   C-locked-late        after LATE more seconds locked (the display may sleep by then);
#   D-off-console        after SACSwitchToLoginWindow (fast user switching): the session is off the
#                        console, like a second login session in the background.
# Each round captures the window four ways (CGWindowListCreateImage, SLSHWCaptureWindowList,
# ScreenCaptureKit window, `screencapture -l`), the displays through ScreenCaptureKit, sends text
# three ways (CGEventPostToPid, AX selected-text write, CGEventPost at the HID tap) and reads the
# document back through AX, then does the same through Cua Driver (get_window_state, type_text).
set -u
# A driver that exits must not take this script with it: a write to its FIFO then fails (EPIPE).
trap '' PIPE
D=/Users/lume/lsc
LATE=$(cat "$D/late" 2>/dev/null || echo 120)
P="$D/lockprobe"
DRV="$D/cua-driver"
O="$D/out"
R="$O/results.jsonl"
mkdir -p "$O"
: >"$R"
note() { printf '{"phase":"%s","note":"%s"}\n' "$1" "$2" >>"$R"; }
tagged() { sed "s/^{/{\"phase\":\"$1\",/" >>"$R"; }

# Cua Driver over MCP stdio (`mcp --direct`, no daemon), in this session.
mcp_id=0
mcp_start() {  # /bin/bash is 3.2 (no coproc): the driver's stdin and stdout are two FIFOs on fds 3 and 4
  rm -f "$D/mcp.in" "$D/mcp.out" && mkfifo "$D/mcp.in" "$D/mcp.out"
  "$DRV" mcp --direct <"$D/mcp.in" >"$D/mcp.out" 2>>"$O/cua-driver.err" &
  MCP_PID=$!
  exec 3>"$D/mcp.in" 4<"$D/mcp.out"
  mcp_rpc initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lockprobe","version":"1"}}' >"$O/mcp-initialize.json"
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
  mcp_rpc tools/list '{}' >"$O/mcp-tools.json"
}
mcp_rpc() {  # METHOD PARAMS: prints the response line with this request's id
  mcp_id=$((mcp_id + 1))
  printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$mcp_id" "$1" "$2" >&3
  local line
  while IFS= read -r -t 90 line <&4; do
    case "$line" in *"\"id\":$mcp_id,"* | *"\"id\":$mcp_id}"*) printf '%s\n' "$line"; return 0 ;; esac
  done
  printf '{"error":"no response to %s in 90 s"}\n' "$1"
}
mcp_call() { mcp_rpc tools/call "{\"name\":\"$1\",\"arguments\":$2}"; }

printf 'lockprobe note\n' >"$D/note.txt"
open -a TextEdit "$D/note.txt"
TE="" WID=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  TE=$(pgrep -nx TextEdit)
  [[ -n "$TE" ]] && WID=$("$P" wid "$TE" note.txt)
  [[ -n "$TE" && "$WID" != 0 ]] && break
done
note setup "textedit pid ${TE:-none} window $WID"
if [[ -z "$TE" || "$WID" == 0 ]]; then
  "$P" windows | tagged setup
  note setup "no TextEdit window for note.txt: nothing to measure"
  echo 3 >"$D/status"
  exit 3
fi
"$P" windows "$TE" | tagged setup
mcp_start
note setup "cua-driver tools: $(grep -o '"name":"[a-z_]*"' "$O/mcp-tools.json" | cut -d'"' -f4 | tr '\n' ' ')"

round() {  # PHASE
  local ph=$1 main
  main=$("$P" main-display)
  note "$ph" begin
  "$P" state | tagged "$ph"
  "$P" capture-cg "$WID" "$O/$ph-cg.png" | tagged "$ph"
  "$P" capture-hw "$WID" "$O/$ph-hw.png" | tagged "$ph"
  "$P" capture-sck "$WID" "$O/$ph-sck.png" | tagged "$ph"
  "$P" capture-sck-display "$main" "$O/$ph-sck-main.png" | tagged "$ph"
  [[ -n "${VDID:-}" ]] && "$P" capture-sck-display "$VDID" "$O/$ph-sck-virtual.png" | tagged "$ph"
  screencapture -x -o -l "$WID" "$O/$ph-screencapture-l.png" 2>>"$O/screencapture.err"
  note "$ph" "screencapture -l exit $? size $(stat -f %z "$O/$ph-screencapture-l.png" 2>/dev/null || echo none)"
  "$P" type "$TE" " pid-$ph" | tagged "$ph"
  "$P" ax-set "$TE" " ax-$ph" | tagged "$ph"
  "$P" type-hid "$TE" " hid-$ph" | tagged "$ph"
  mcp_call type_text "{\"pid\":$TE,\"window_id\":$WID,\"text\":\" cua-$ph\"}" >"$O/$ph-cua-type.json"
  "$P" mcp-result "$O/$ph-cua-type.json" "$O/$ph-cua-type.png" | tagged "$ph-cua-type_text"
  # A key and a pixel click, Cua Driver's background routes: the key lands as an "x" in the document.
  mcp_call press_key "{\"pid\":$TE,\"window_id\":$WID,\"key\":\"x\"}" >"$O/$ph-cua-key.json"
  "$P" mcp-result "$O/$ph-cua-key.json" "$O/$ph-cua-key.png" | tagged "$ph-cua-press_key"
  mcp_call click "{\"pid\":$TE,\"window_id\":$WID,\"x\":200,\"y\":200}" >"$O/$ph-cua-click.json"
  "$P" mcp-result "$O/$ph-cua-click.json" "$O/$ph-cua-click.png" | tagged "$ph-cua-click"
  # Wait (5 s at most: a route may not land while locked) until the document has Cua Driver's text.
  for _ in $(seq 50); do
    "$P" ax-text "$TE" | grep -q "cua-$ph" && break
    sleep 0.1
  done
  "$P" ax-text "$TE" | tagged "$ph"
  mcp_call get_window_state "{\"pid\":$TE,\"window_id\":$WID}" >"$O/$ph-cua-state.json"
  "$P" mcp-result "$O/$ph-cua-state.json" "$O/$ph-cua-state.png" | tagged "$ph-cua-get_window_state"
  "$P" capture-hw "$WID" "$O/$ph-after-hw.png" | tagged "$ph-after"
  "$P" capture-sck "$WID" "$O/$ph-after-sck.png" | tagged "$ph-after"
  rm -f "$O/$ph-cua-state.json"  # holds the base64 screenshot already written as PNG
}

round A-unlocked

"$P" vdisplay $((LATE + 3600)) >"$O/vdisplay.jsonl" 2>"$O/vdisplay.err" &
VPID=$!
# The display exists once vdisplay prints its id (or an error) as its first line.
for _ in $(seq 200); do
  [[ -s "$O/vdisplay.jsonl" ]] && break
  kill -0 "$VPID" 2>/dev/null || break
  sleep 0.1
done
[[ -s "$O/vdisplay.jsonl" ]] || note vdisplay "vdisplay printed nothing in 20 s"
VDID=$(head -1 "$O/vdisplay.jsonl" | sed -n 's/.*"display_id":\([0-9]*\).*/\1/p')
note vdisplay "vdisplay pid $VPID id ${VDID:-none}"
head -1 "$O/vdisplay.jsonl" | tagged vdisplay
if [[ -n "$VDID" && "$VDID" != 0 ]]; then
  VX=$("$P" display-x "$VDID")
  "$P" move-window "$TE" $(( VX + 100 )) 100 | tagged vdisplay
  # Wait until the window server has the window on the virtual display (its X where the move put it).
  win_x() { "$P" windows "$TE" | grep -o "\"bounds\":{[^}]*},\"id\":$WID," | sed -n 's/.*"X":\(-\{0,1\}[0-9]*\).*/\1/p'; }
  for _ in $(seq 100); do
    x=$(win_x); [[ -n "$x" ]] && (( x - VX - 100 <= 50 && VX + 100 - x <= 50 )) && break
    sleep 0.1
  done
  x=$(win_x); [[ -n "$x" ]] && (( x - VX - 100 <= 50 && VX + 100 - x <= 50 )) || note vdisplay "window $WID not on the virtual display 10 s after the move (x ${x:-none})"
  round A2-unlocked-virtual
else
  VDID=""
fi

"$P" lock | tagged lock
# Wait until the session reports the screen locked (best-effort: round B runs either way).
for _ in $(seq 200); do
  "$P" state | grep -Eq '"locked":(true|1)' && break
  sleep 0.1
done
"$P" state | grep -Eq '"locked":(true|1)' || note lock "session not locked 20 s after lock"
round B-locked

note C-locked-late "waiting $LATE s locked"
sleep "$LATE"  # sleep-ok: the round measures after LATE seconds locked (the displays may sleep by then)
round C-locked-late

# Fast user switching to the login window: this session leaves the console, as a second login
# session in the background would be.
"$P" switch-out | tagged switch-out
# Wait until this session is off the console (best-effort: round D runs either way).
off_console() { "$P" state | grep -Eq '"on_console":(false|0)|"session":"none"'; }
for _ in $(seq 300); do
  off_console && break
  sleep 0.1
done
off_console || note switch-out "session still on the console 30 s after switch-out"
round D-off-console

kill "$VPID" 2>/dev/null
exec 3>&-
kill "$MCP_PID" 2>/dev/null
note done "$(date -u +%FT%TZ)"
echo 0 >"$D/status"
