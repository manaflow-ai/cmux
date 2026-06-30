#!/bin/bash
# ============================================================================
# Remote-tmux mirror RENDER-FIDELITY harness.
#
# Asserts the strong oracle that a weaker "is there a stray %?" check can't:
#
#     the mirror's rendered VISIBLE screen  ==  the remote pane's VISIBLE screen
#
# (after the attach/resize settles, at matched size). This catches the LAYOUT/CONTENT
# class of mirror render bugs at once: stacked/compacted prompts, the spurious zsh
# PROMPT_SP "%", history-in-the-visible-area, and any content drift — which is how a
# mis-seeded cursor usually surfaces too. It does NOT compare the cursor cell directly
# (read-screen returns text only); the cursor-placement logic is covered by the
# paneStateSeedSequence unit tests. It drives every edge that has regressed: fresh
# attach, prompt-redraw scrollback, mirror taller than the pane (H>P), mirror shorter
# (H<P), rapid re-attach, reconnect, and a mid-size pane.
#
# PREREQUISITES:
#   - A tagged Debug app built + running:  ./scripts/reload.sh --tag <tag> --launch
#     then run this with CMUX_TAG=<tag>.
#   - An ssh alias to localhost whose forced-command pins an isolated TMUX_TMPDIR,
#     so the harness never touches your real tmux. Defaults to `cmux-srvA` ->
#     /tmp/cmux-srvA. Example ~/.ssh/config:
#         Host cmux-srvA
#             HostName 127.0.0.1
#             RemoteCommand TMUX_TMPDIR=/tmp/cmux-srvA $SHELL -l
#             RequestTTY yes
#     Override with CMUX_RENDER_SRV / CMUX_RENDER_SRV_TMPDIR.
#
# Exit code is the number of failed scenarios (0 = all green).
# ============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CMUX_TAG:?set CMUX_TAG to the tagged debug app (e.g. CMUX_TAG=lv-all)}"
TMUXBIN="${CMUX_RENDER_TMUX:-/opt/homebrew/bin/tmux}"
SRV="${CMUX_RENDER_SRV:-cmux-srvA}"
SRVDIR="${CMUX_RENDER_SRV_TMPDIR:-/tmp/cmux-srvA}"
UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

cli() { CMUX_TAG="$CMUX_TAG" timeout 25 "$REPO/scripts/cmux-debug-cli.sh" "$@" 2>&1; }
win_ids() { cli list-windows | awk '{for(i=1;i<=NF;i++) if($i ~ /^selected_workspace=/) print $(i-1)}'; }
# Normalize for comparison: right-trim each line, drop trailing blank lines.
norm() { sed 's/[[:space:]]*$//' | awk '{a[NR]=$0} END{last=NR; while(last>0 && a[last]=="") last--; for(i=1;i<=last;i++) print a[i]}'; }
remote_visible() { TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" capture-pane -p -t "$1" 2>/dev/null | norm; }
mirror_visible() { cli read-screen --window "$1" 2>/dev/null | norm; }
remote_pane_info() { TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" display-message -p -t "$1" 'size=#{pane_width}x#{pane_height} cursor=#{cursor_x},#{cursor_y} hist=#{history_size}' 2>/dev/null; }

reset_srv() { TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" kill-server 2>/dev/null; sleep 0.3; mkdir -p "$SRVDIR"; }
gen_scrollback() { local s="$1" n="$2" i; for ((i=0;i<n;i++)); do TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" send-keys -t "$s" Enter; done; sleep 0.6; }
attach_window() {
  local before; before=$(win_ids | sort -u)
  cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1; sleep 3
  win_ids | sort -u | comm -13 <(printf '%s\n' "$before") - | grep -iE "$UUID" | head -1
}

PASS=0; FAIL=0; FAILED=""
assert_match() {  # $1=label  $2=remote_session  $3=mirror_window
  local label="$1" rs="$2" w="$3" r m i
  if [ -z "$w" ]; then FAIL=$((FAIL+1)); FAILED="$FAILED $label(no-window)"; echo "  FAIL  $label  (no mirror window)"; return; fi
  # Re-compare a few times before failing: the mirror sizes the remote client on
  # attach (refresh-client -C) and the pane reflows asynchronously, so the settled
  # frame can land a beat after the initial 3s wait. A real render bug stays
  # mismatched across every retry; only a slow settle is absorbed here.
  for i in 1 2 3 4 5; do
    r=$(remote_visible "$rs"); m=$(mirror_visible "$w")
    [ "$r" = "$m" ] && break
    sleep 1.5
  done
  if [ "$r" = "$m" ]; then
    PASS=$((PASS+1)); echo "  PASS  $label"
  else
    FAIL=$((FAIL+1)); FAILED="$FAILED $label"
    echo "  FAIL  $label  ($(remote_pane_info "$rs"))"
    echo "        remote=$(printf '%s' "$r" | grep -c .) non-blank lines  mirror=$(printf '%s' "$m" | grep -c .) non-blank lines"
    paste <(printf '%s\n' "$r" | cat -n) <(printf '%s\n' "$m" | cat -n) | head -8 | sed 's/^/        /'
  fi
  cli close-window --window "$w" >/dev/null 2>&1; sleep 0.4
}

echo "=== remote-tmux render-fidelity harness  tag=$CMUX_TAG  srv=$SRV ==="

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s1; sleep 0.8
assert_match "fresh-empty" s1 "$(attach_window)"

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s2; sleep 0.8; gen_scrollback s2 8
assert_match "scrollback-history" s2 "$(attach_window)"

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s3 -x 80 -y 12; sleep 0.8; gen_scrollback s3 6
assert_match "mirror-taller-HgtP" s3 "$(attach_window)"

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s4 -x 80 -y 60; sleep 0.8; gen_scrollback s4 4
assert_match "mirror-shorter-HltP" s4 "$(attach_window)"

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s6; sleep 0.8; gen_scrollback s6 5
before=$(win_ids | sort -u)
cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1; cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1; sleep 3
assert_match "rapid-reattach" s6 "$(win_ids | sort -u | comm -13 <(printf '%s\n' "$before") - | grep -iE "$UUID" | head -1)"

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s7; sleep 0.8; gen_scrollback s7 5
before=$(win_ids | sort -u); cli ssh-tmux "$SRV" --no-focus >/dev/null 2>&1; sleep 3
W7=$(win_ids | sort -u | comm -13 <(printf '%s\n' "$before") - | grep -iE "$UUID" | head -1)
pkill -f "ssh.*$SRV" 2>/dev/null; sleep 6
r=$(remote_visible s7); m=$(mirror_visible "$W7")
if [ "$r" = "$m" ]; then PASS=$((PASS+1)); echo "  PASS  reconnect-reseed"; else FAIL=$((FAIL+1)); FAILED="$FAILED reconnect-reseed"; echo "  FAIL  reconnect-reseed"; fi
cli close-window --window "$W7" >/dev/null 2>&1; sleep 0.4

reset_srv; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" new-session -d -s s8 -x 100 -y 20; sleep 0.8; gen_scrollback s8 6
assert_match "midsize-pane" s8 "$(attach_window)"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -gt 0 ] && echo "FAILED:$FAILED"
TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" kill-server 2>/dev/null
exit "$FAIL"
