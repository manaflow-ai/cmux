#!/bin/bash
# remote-tmux-width-probe — live, flicker-free width truth for one tmux pane.
#
# Run it inside a pane of a mirrored tmux window (or any tmux pane). Every
# ~250ms it shows the PTY size, the tmux pane/window/client widths, a check
# line, and a ruler drawn EXACTLY PTY-wide:
#
#   - ruler wraps        -> the rendering surface is NARROWER than the PTY:
#                           full-width output wraps (the stranded-"%" bug).
#   - ruler falls short  -> the surface is wider than the PTY.
#   - check ✗ at rest    -> tmux assigned the pane a different width than its PTY.
#
# A resize log (newest last) records every PTY/pane/window transition, so a
# bug report can show exactly how a size settled. Frames are wrapped in
# synchronized output (DEC mode 2026) and overwrite in place, so the probe
# never flickers. Quit with q.
set -u
# Loop state (set -u requires explicit initialization).
last=""
HIST=()
trap 'printf "\033[?25h\n"; exit 0' INT TERM
printf '\033[?25l'
# Liveness marker: harnesses (shape-zoo launcher, sizing e2e suite) poll the
# @probe_alive pane option instead of guessing from timing or foreground
# command names, so an overloaded machine can't start measuring before the
# probe is actually running. The option dies with the pane; quitting clears
# it explicitly so a stopped probe never reads as alive.
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux set-option -p -t "$TMUX_PANE" @probe_alive 1 2>/dev/null || true
  trap 'tmux set-option -p -t "$TMUX_PANE" -u @probe_alive 2>/dev/null; printf "\033[?25h\n"; exit 0' INT TERM
fi
while :; do
  # what the PTY says (authoritative "what tmux told this shell")
  set -- $(stty size < /dev/tty 2>/dev/null || echo "? ?")
  rows=$1 cols=$2
  # what tmux says (when this shell runs inside the mirrored session)
  pane="-" pw="-" win="-" ww="-" cw="-"
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    # -t $TMUX_PANE: without it, display-message reports the client's ACTIVE
    # pane — whatever tab the user is looking at, not this one. Fields are
    # pipe-delimited and read with defaults: any of them (esp. client_width,
    # before a -CC client has attached) can expand EMPTY, and set -u would
    # kill the loop on a bare positional.
    IFS='|' read -r pane pw ph win ww sess <<< "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}|#{pane_width}|#{pane_height}|#{window_id}|#{window_width}|#{session_name}' 2>/dev/null)"
    pane=${pane:--} pw=${pw:--} ph=${ph:--} win=${win:--} ww=${ww:--}
    cw=$(tmux list-clients -t "${sess:-}" -F '#{client_width}' 2>/dev/null | head -1)
    cw=${cw:-none}
  fi
  now=$(date +%H:%M:%S)
  state="PTY ${cols}x${rows} | pane $pane=${pw}x${ph} | win $win=$ww | client=$cw"
  if [ "$state" != "$last" ]; then
    HIST+=("$now  $state")
    [ ${#HIST[@]} -gt 12 ] && HIST=("${HIST[@]:1}")
    last="$state"
  fi
  # verdicts we can compute from in here
  skew=""
  if [ "$pw" != "-" ]; then
    if [ "$pw" = "$cols" ] && [ "$ph" = "$rows" ]; then
      skew="PTY == tmux pane (both axes) ✓"
    else
      skew="PTY ${cols}x${rows} ≠ tmux pane ${pw}x${ph} ✗"
    fi
  fi
  # frame — every info line is truncated to the PTY width so a narrow pane
  # shows a clean (if terse) frame instead of wrapped soup; only the ruler
  # is deliberately exactly PTY-wide. The layout is HEIGHT-AWARE: in a short
  # pane (a stacked row) the ruler and the check verdict always survive and
  # everything else earns its row by priority, so the probe's point is never
  # the thing that scrolls away.
  # Flicker-free redraw: synchronized output (DEC mode 2026 — the terminal
  # holds the frame and swaps atomically) + home-and-overwrite with per-line
  # erase-to-EOL instead of a full-screen clear (2J blanks a visible frame).
  ln() { printf '%.*s\033[K\n' "$cols" "$1"; }
  ruler() { printf '%*s' "$cols" '' | tr ' ' '='; printf '\033[K\n'; }
  mark="-"
  if [ "$pw" != "-" ]; then
    if [ "$pw" = "$cols" ] && [ "$ph" = "$rows" ]; then mark="✓"; else mark="✗"; fi
  fi
  printf '\033[?2026h\033[H'
  if [ "$rows" -le 1 ]; then
    ruler
  elif [ "$rows" -le 3 ]; then
    # status + ruler (+ caption at 3): the essentials for a sliver-row pane
    ln "$mark ${cols}x${rows} pane=$pw win=$ww"
    ruler
    [ "$rows" -ge 3 ] && ln "^ ruler=PTY; wraps: PTY>surface"
  elif [ "$rows" -le 7 ]; then
    ln "pane-width-live $now (q quits)"
    ln "$mark PTY ${cols}x${rows} | pane $pane=$pw | win $win=$ww | client=$cw"
    ruler
    ln "^ ruler=PTY width; wraps: PTY>surface | short: PTY<surface"
    logroom=$((rows - 5))
    if [ "$logroom" -gt 0 ] && [ ${#HIST[@]} -gt 0 ]; then
      start=$(( ${#HIST[@]} > logroom ? ${#HIST[@]} - logroom : 0 ))
      for l in "${HIST[@]:$start}"; do ln " $l"; done
    fi
  else
    ln "pane-width-live $now (q quits)"
    ln "PTY: ${cols}x${rows}"
    if [ -n "${TMUX:-}" ]; then
      ln "tmux: pane $pane=${pw}w win $win=${ww}w client=${cw}w"
      ln "check: $skew"
    else
      ln "tmux: (not inside tmux)"
    fi
    ln "ruler (=PTY width; compare to border):"
    ruler
    ln "^ wraps: PTY>surface | short: PTY<surface"
    ln ""
    ln "resize log (newest last):"
    logroom=$((rows - 10))
    if [ "$logroom" -gt 0 ] && [ ${#HIST[@]} -gt 0 ]; then
      start=$(( ${#HIST[@]} > logroom ? ${#HIST[@]} - logroom : 0 ))
      for l in "${HIST[@]:$start}"; do ln " $l"; done
    fi
  fi
  # erase leftovers below the frame, then paint the BOTTOM SENTINEL on the
  # exact last PTY row (no trailing newline — that would scroll): the
  # vertical twin of the ruler. Sentinel visible = render is at least PTY
  # tall; sentinel clipped = the surface is SHORTER than the PTY (the
  # height analog of a wrapped ruler). Skipped when the ruler itself is on
  # the last row.
  printf '\033[J'
  if [ "$rows" -ge 3 ]; then
    # ASCII only: multibyte pad glyphs make byte-based length/precision
    # arithmetic slice mid-character in C-locale shells (short sentinel +
    # a stray replacement char). Underscores also hug the cell bottom —
    # right where a bottom-edge witness belongs.
    sentinel=$(printf 'bottom row %d %s' "$rows" "$(printf '%*s' "$cols" '' | tr ' ' '_')")
    printf '\033[%d;1H%.*s\033[K' "$rows" "$cols" "$sentinel"
  fi
  printf '\033[?2026l'
  # quit on q; tick rate via PROBE_TICK (seconds, default 0.25 ≈ 4Hz —
  # lower the rate when running MANY probes at once: each frame is real
  # %output through the whole mirror pipeline)
  if read -r -s -t "${PROBE_TICK:-0.25}" -n 1 key 2>/dev/null; then [ "$key" = "q" ] && { printf '\033[?25h\n'; exit 0; }; fi
done
