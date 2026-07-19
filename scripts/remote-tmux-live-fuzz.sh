#!/bin/bash
# Live layout fuzz for the remote-tmux mirror: the real app mirroring a real
# tmux server, driven with random layouts and random churn. The unit fuzz
# checks the sizing math; this one checks what actually lands on screen.
#
# Builds a random pane layout in an isolated tmux server, lets the running
# tagged app mirror it, then applies random mutations — tmux-side pane
# resizes, window switches, splits and kills, and app-window resizes via the
# DEBUG rpc — and after each settle checks two things:
#   1. the app's sizing-settlement probe: every pane renders the tmux-assigned
#      grid once the claim and layout agree;
#   2. per-pane text: read-screen output equals tmux capture-pane for every
#      pane surface.
# Every failure prints the seed and iteration so the run reproduces exactly.
#
# Usage: CMUX_TAG=main scripts/remote-tmux-live-fuzz.sh <ssh-host> [seed] [iters]
# Requires: the tagged DEBUG app running with remoteTmux enabled, an isolated
# tmux server behind <ssh-host> (TMUX_TMPDIR wrapper), and the debug CLI.
set -u
umask 077

HOST="${1:?usage: CMUX_TAG=<tag> $0 <ssh-host> [seed] [iters]}"
SEED="${2:-1}"
ITERS="${3:-25}"
: "${CMUX_TAG:?CMUX_TAG is required}"
FUZZ_HOST_NAME="${HOST##*@}"
case "$FUZZ_HOST_NAME" in
  ''|*[!A-Za-z0-9._-]*) echo "invalid fuzz host name: $FUZZ_HOST_NAME" >&2; exit 2 ;;
esac
DEFAULT_TMUX_TMPDIR="$HOME/Library/Caches/cmux/remote-tmux-fuzz/${FUZZ_HOST_NAME}-tmux"
TMPDIR_REMOTE="${CMUX_FUZZ_TMUX_TMPDIR:-$DEFAULT_TMUX_TMPDIR}"
DEBUG_LOG="${CMUX_FUZZ_DEBUG_LOG:-/tmp/cmux-debug-${CMUX_TAG}.log}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/cmux-debug-cli.sh"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || {
  echo "ERROR: neither 'timeout' nor 'gtimeout' found; install GNU coreutils (brew install coreutils)" >&2
  exit 2
}
. "$HERE/remote-tmux-fuzz-lock.sh"
SETTLE="${CMUX_FUZZ_SETTLE_SECS:-6}"
SESSION=fuzz
DRY="${CMUX_FUZZ_DRY:-0}"
LOCAL_TMP_ROOT="${TMPDIR:-/tmp}"
LOCAL_TMP_ROOT="${LOCAL_TMP_ROOT%/}"
RUN_DIR=$(mktemp -d "$LOCAL_TMP_ROOT/cmux-remote-tmux-fuzz.XXXXXXXX") || {
  echo "could not create private fuzz run directory" >&2
  exit 2
}
RULER="$RUN_DIR/ruler.sh"
WORKSPACE_REF=""
CMUX_FUZZ_LOCK_OWNED=0
FUZZ_SERVER_OWNED=0

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$DRY" != 1 ] && [ -n "$WORKSPACE_REF" ]; then
    "$CLI" workspace close "$WORKSPACE_REF" >/dev/null 2>&1
  fi
  if [ "$FUZZ_SERVER_OWNED" = 1 ]; then
    t kill-server >/dev/null 2>&1 || true
  fi
  cmux_fuzz_lock_release
  rm -rf -- "$RUN_DIR"
  exit "$status"
}
trap cleanup EXIT

# Deterministic RNG (LCG) so a seed reproduces the exact op sequence.
# Returns via the global R: command substitution would fork a subshell and
# the state would never advance — a fuzzer repeating one op forever while
# reporting green is worse than no fuzzer.
state=$SEED
rand() { state=$(( (state * 1103515245 + 12345) % 2147483648 )); R=$(( state % $1 )); }

# One fuzz driver at a time, marathon or standalone: both churn the same
# app and the same lab tmux server, and a second driver's per-seed
# kill-server yanks layouts out from under the first, manufacturing
# failures no code produced. The marathon holds the lock for its whole
# run and passes its private directory + token to each child.
if [ "${CMUX_FUZZ_LOCK_HELD:-0}" = 1 ]; then
  cmux_fuzz_lock_validate_inherited || exit $?
else
  cmux_fuzz_lock_acquire "$LOCAL_TMP_ROOT" || exit $?
fi

t() { TMUX_TMPDIR="$TMPDIR_REMOTE" tmux "$@"; }
fail=0
note_fail() { echo "FUZZ FAIL seed=$SEED iter=$1: $2"; fail=$((fail + 1)); }

settlement_has_schema() {
  printf '%s' "$1" | jq -e '
    (.connected | type == "boolean") and (.windows | type == "array")
  ' >/dev/null 2>&1
}

settlement_has_reported_windows() {
  printf '%s' "$1" | jq -e '.windows | length > 0' >/dev/null 2>&1
}

settlement_ready() {
  printf '%s' "$1" | jq -e '
    .connected == true
    and (.windows | type == "array")
    and (.windows | length > 0)
    and all(.windows[];
      .settled == true
      and ((.mismatches // []) | all(.[]; contains("no-sample") | not))
    )
  ' >/dev/null 2>&1
}

settlement_clean() {
  printf '%s' "$1" | jq -e '
    .connected == true
    and (.windows | type == "array")
    and (.windows | length > 0)
    and all(.windows[]; .settled == true and ((.mismatches // []) | length == 0))
  ' >/dev/null 2>&1
}

settlement_has_render_mismatch() {
  printf '%s' "$1" | jq -e '
    any(.windows[]?; ((.mismatches // []) | any(.[]; test("rendered=|misplaced"))))
  ' >/dev/null 2>&1
}

settlement_is_unsettled() {
  printf '%s' "$1" | jq -e '
    .connected != true or any(.windows[]?; .settled != true)
  ' >/dev/null 2>&1
}

settlement_mismatch_lines() {
  printf '%s' "$1" | jq -r '
    [.windows[]?.mismatches[]? | select(test("rendered=|misplaced"))][0:4][]
  '
}

normalize_screen() {
  sed 's/[[:space:]]*$//' \
    | awk '{lines[NR]=$0} END {last=NR; while (last > 0 && lines[last] == "") last--; for (i=1; i<=last; i++) print lines[i]}'
}

REMOTE_SCREEN=""
MIRROR_SCREEN=""
capture_remote_screen() {
  local pane=$1 raw
  raw=$(t capture-pane -p -J -t "$pane" 2>/dev/null) || return 1
  REMOTE_SCREEN=$(printf '%s\n' "$raw" | normalize_screen)
}

capture_mirror_screen() {
  local raw
  raw=$("$TIMEOUT_BIN" 8 "$CLI" read-screen --window "$WINDOW_ID" 2>/dev/null) || return 1
  MIRROR_SCREEN=$(printf '%s\n' "$raw" | normalize_screen)
}

compare_pane_screen() {
  local pane=$1 deadline before after
  t select-pane -t "$pane" >/dev/null 2>&1 || return 1
  deadline=$((SECONDS + 6))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if capture_remote_screen "$pane"; then
      before=$REMOTE_SCREEN
      if capture_mirror_screen && capture_remote_screen "$pane"; then
        after=$REMOTE_SCREEN
        # The ruler redraws every two seconds. Accept the mirror matching the
        # remote capture immediately before OR after it, so a redraw between
        # the two reads cannot manufacture a content mismatch.
        if [ "$MIRROR_SCREEN" = "$before" ] || [ "$MIRROR_SCREEN" = "$after" ]; then
          return 0
        fi
      fi
    fi
    sleep 0.25
  done
  return 1
}

check_screen_oracle() {
  local iter=$1 settled_json=$2 windows window panes pane remote_lines mirror_lines
  windows=$(printf '%s' "$settled_json" | jq -r '
    .windows[]?
    | select(.settled == true)
    | .window
    | if type == "number" then tostring
      elif type == "string" then ltrimstr("@")
      else empty
      end
    | select(test("^[0-9]+$"))
    | "@" + .
  ' 2>/dev/null) || windows=""
  if [ -z "$windows" ]; then
    if settlement_has_reported_windows "$settled_json"; then
      note_fail "$iter" "text oracle could not parse settled tmux window ids"
      return
    fi
    # Single-pane mirrors are omitted from sizing_settled because they need no
    # native split plan. The tmux session's active window is the visible tab.
    windows=$(t display -t "$SESSION" -p '#{window_id}' 2>/dev/null) || windows=""
  fi
  if [ -z "$windows" ]; then
    note_fail "$iter" "text oracle found no settled or active tmux window"
    return
  fi

  while IFS= read -r window; do
    [ -n "$window" ] || continue
    panes=$(t list-panes -t "$window" -F '#{pane_id}' 2>/dev/null) || panes=""
    if [ -z "$panes" ]; then
      note_fail "$iter" "text oracle could not list panes for $window"
      continue
    fi
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      if compare_pane_screen "$pane"; then
        continue
      fi
      note_fail "$iter" "pane $pane mirror read-screen differs from tmux capture-pane in $window"
      remote_lines=$(printf '%s\n' "$REMOTE_SCREEN" | grep -c . || true)
      mirror_lines=$(printf '%s\n' "$MIRROR_SCREEN" | grep -c . || true)
      echo "  text evidence pane=$pane remote_lines=$remote_lines mirror_lines=$mirror_lines"
      diff -u \
        <(printf '%s\n' "$REMOTE_SCREEN") \
        <(printf '%s\n' "$MIRROR_SCREEN") \
        | head -40 | sed 's/^/  /' || true
    done <<< "$panes"
  done <<< "$windows"
}

# Fresh lab: 2 windows, random pane counts, ruler panes that redraw to their
# tty size every 2s (a wrapped ruler is visible in text comparison).
mkdir -p "$TMPDIR_REMOTE"
if t list-sessions >/dev/null 2>&1; then
  echo "FUZZ SETUP FAIL seed=$SEED: tmux server already exists under $TMPDIR_REMOTE; refusing to kill an unowned lab" >&2
  exit 98
fi
FUZZ_SERVER_OWNED=1
cat > "$RULER" <<'EOF'
#!/bin/sh
unset COLUMNS LINES
while :; do
  sz=$(stty size 2>/dev/null); rows=${sz%% *}; cols=${sz##* }
  [ -n "$rows" ] || rows=24; [ -n "$cols" ] || cols=80
  base=$(printf '%0.s0123456789' $(seq 1 60))
  printf '\033[2J\033[H'
  r=1
  while [ "$r" -lt "$rows" ]; do
    printf '%s\n' "$(printf '%03dx%03d %s' "$cols" "$rows" "$base" | cut -c1-"$cols")"
    r=$((r+1))
  done
  printf 'END %03dx%03d' "$cols" "$rows"
  sleep 2
done
EOF
chmod +x "$RULER"
printf -v RULER_COMMAND 'sh %q' "$RULER"

env -u COLUMNS -u LINES TMUX_TMPDIR="$TMPDIR_REMOTE" \
  tmux new-session -d -s $SESSION -n w0 -x 200 -y 50 "$RULER_COMMAND"
for w in 0 1; do
  [ "$w" = 1 ] && t new-window -t $SESSION -n w1 "$RULER_COMMAND"
  rand 5; panes=$(( 2 + R ))
  for _ in $(seq 2 "$panes"); do
    rand 2
    if [ "$R" = 0 ]; then
      t split-window -h -t $SESSION:w$w "$RULER_COMMAND" 2>/dev/null
    else
      t split-window -v -t $SESSION:w$w "$RULER_COMMAND" 2>/dev/null
    fi
    t select-layout -t $SESSION:w$w tiled
  done
done

if [ "$DRY" = 1 ]; then
  # Dry mode: run the exact op sequence against tmux alone and log the
  # layout after every step, so the op mix's coverage can be inspected
  # without the app: do we reach deep nests, tiny panes, many windows —
  # or does the distribution collapse into boring shapes?
  CONNECT_OUT=""
else
  CONNECT_OUT=$("$CLI" ssh-tmux "$HOST" 2>/dev/null | tail -1)
fi
WINDOW_ID="${CMUX_FUZZ_WINDOW_ID:-$(printf '%s' "$CONNECT_OUT" | sed -n 's/.*window=\([A-F0-9-]*\).*/\1/p')}"

# Attach barrier: the gate judges STEADY-STATE churn, so iteration 1 must
# not begin until the initial claim/layout handshake has settled once.
# Back-to-back seeds (teardown then reconnect) can take tens of seconds to
# converge; that latency is real and printed here as its own measurement,
# but it is attach convergence, not the sizing invariant this harness
# gates. A connect that never settles at all still fails iteration 1.
if [ "$DRY" != 1 ]; then
  attach_start=$SECONDS
  tries=0
  while [ "$tries" -lt 30 ]; do
    aj=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.sizing_settled 2>/dev/null)
    if settlement_ready "$aj"; then
      break
    fi
    tries=$((tries + 1))
    sleep 2
  done
  echo "attach settled in $((SECONDS - attach_start))s (polls=$tries)"
fi

check_iter() {
  local iter=$1
  # Hang detector: if the app stops answering the socket, that IS the bug.
  # Exit with a distinct code so a marathon wrapper can sample the process,
  # keep the evidence, and restart.
  if ! "$TIMEOUT_BIN" 8 "$CLI" ping >/dev/null 2>&1; then
    echo "FUZZ HANG seed=$SEED iter=$iter: app socket unresponsive"
    exit 99
  fi
  # Ask the app whether everything has finished settling, instead of
  # guessing with a timer. Poll up to 20s; a window that never settles is
  # itself a failure, and any pane mismatch reported WHILE settled is a
  # real rendering bug — no transition ambiguity.
  local settled_json="" tries=0
  while [ "$tries" -lt 10 ]; do
    settled_json=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.sizing_settled 2>/dev/null)
    # A failed or timed-out RPC has no windows KEY at all — that is absence
    # of evidence, not settledness. Keep polling; exhausting the loop
    # reports it as never settled with whatever came back.
    if ! settlement_has_schema "$settled_json"; then
      tries=$((tries + 1))
      sleep 2
      continue
    fi
    # An EMPTY window list is settled only when there is genuinely nothing
    # to judge: the visible tab mirrors a single-pane window. If the lab's
    # active window has several panes, empty means the fuzz mirror is not
    # the visible workspace — the gate would be blind, so re-select it and
    # keep polling; exhausting the loop then reports the failure.
    if ! settlement_has_reported_windows "$settled_json"; then
      local active_panes
      active_panes=$(t display -t $SESSION -p '#{window_panes}' 2>/dev/null || echo 1)
      if [ "${active_panes:-1}" -le 1 ]; then
        break
      fi
      "$CLI" workspace select "$WORKSPACE_REF" >/dev/null 2>&1
      tries=$((tries + 1))
      sleep 2
      continue
    fi
    # A pane with no sizing sample yet is still in transition even when the
    # window's claim/layout dims agree — keep polling until every pane has
    # reported. A rendered-grid mismatch does NOT block the break: a pane
    # wrong AT settle is exactly the bug this harness exists to capture,
    # and waiting it out would misreport it as "never settled".
    if settlement_ready "$settled_json"; then
      break
    fi
    tries=$((tries + 1))
    sleep 2
  done
  # Re-confirm before failing: an end-of-seed relayout storm or a reconnect
  # can leave a window a few seconds from convergence when the 20s poll
  # expires, and a mismatch read mid-transition is not a mismatch at rest.
  # Poll a final stretch; only a state that STAYS wrong is a defect. The
  # extra convergence time is logged so slow-to-settle never hides — a
  # window that needs the reconfirm every time is its own signal.
  reconfirm_needed=0
  if [ "$tries" -ge 10 ] || settlement_has_render_mismatch "$settled_json"; then
    reconfirm_needed=1
    rc_tries=0
    while [ "$rc_tries" -lt 15 ]; do
      sleep 2
      settled_json=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.sizing_settled 2>/dev/null)
      if settlement_clean "$settled_json"; then
        echo "  reconfirm: converged after $(( (rc_tries + 1) * 2 ))s extra (iter $iter)"
        reconfirm_needed=0
        break
      fi
      rc_tries=$((rc_tries + 1))
    done
  fi
  if [ "$reconfirm_needed" = 1 ]; then
    if ! settlement_has_schema "$settled_json" \
       || ! settlement_has_reported_windows "$settled_json" \
       || settlement_is_unsettled "$settled_json"; then
      note_fail "$iter" "windows never settled after 50s: $(printf '%s' "$settled_json" | tr -d '\n' | cut -c1-300)"
    else
      note_fail "$iter" "settled with pane mismatches (persisted through reconfirm):"
      settlement_mismatch_lines "$settled_json" | sed 's/^/  /'
    fi
  fi
  # Oracle 2: select every pane in the settled visible tmux window and compare
  # the mirror's actual terminal text with tmux's capture. This crosses the
  # control connection, pane-focus routing, Ghostty surface, and debug CLI;
  # sizing_settled alone cannot detect content corruption along that path.
  if settlement_has_schema "$settled_json" && ! settlement_is_unsettled "$settled_json"; then
    check_screen_oracle "$iter" "$settled_json"
  fi
  # Ruler liveness: every ruler redrew to its actual pane size on the tmux side
  # (a stale ruler would make on-screen text look mangled without any
  # rendering bug — see op 8's comment).
  for pane in $(t list-panes -s -t $SESSION -F '#{pane_id}'); do
    local got
    got=$(t display -t "$pane" -p '#{pane_width}')
    local first
    first=$(t capture-pane -p -J -t "$pane" 2>/dev/null | grep -m1 "^[0-9]*x[0-9]* 01" | wc -c | tr -d ' ')
    if [ -n "$first" ] && [ "$first" -gt 1 ] && [ $((first - 1)) -ne "$got" ]; then
      # The ruler redraws every 2s and lags further under multi-window
      # load; confirm with two spaced re-reads before calling it a
      # failure, and tolerate the pane dying mid-check.
      confirmed=1
      for _ in 1 2; do
        sleep 3
        got=$(t display -t "$pane" -p '#{pane_width}' 2>/dev/null) || { confirmed=0; break; }
        first=$(t capture-pane -p -J -t "$pane" 2>/dev/null | grep -m1 "^[0-9]*x[0-9]* 01" | wc -c | tr -d ' ')
        if [ -z "$first" ] || [ "$first" -le 1 ] || [ -z "$got" ] || [ $((first - 1)) -eq "$got" ]; then
          confirmed=0
          break
        fi
      done
      if [ "$confirmed" = 1 ]; then
        note_fail "$iter" "pane $pane tmux-side ruler ${first}c != width ${got} after two confirms"
      fi
    fi
  done
}

# Both return via globals (RW / RP): command substitution would fork a
# subshell and the RNG state would never advance — and `sort -R` would pick
# with system randomness, so the same seed would not replay the same run.
random_window() {
  local names count
  names=$(t list-windows -t $SESSION -F '#{window_name}')
  count=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
  rand "$count"
  RW="$SESSION:$(printf '%s\n' "$names" | sed -n "$((R + 1))p")"
}
random_pane() {
  local ids count
  ids=$(t list-panes -t "$1" -F '#{pane_id}')
  count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
  rand "$count"
  RP=$(printf '%s\n' "$ids" | sed -n "$((R + 1))p")
}

app_resize() {
  rand 1400; local width=$(( 900 + R ))
  rand 500; local height=$(( 500 + R ))
  [ -n "${WINDOW_ID:-}" ] && "$CLI" rpc remote.tmux.test_set_frame \
    "{\"window_id\":\"$WINDOW_ID\",\"width\":$width,\"height\":$height}" >/dev/null 2>&1
}

do_op() {
  local w
  random_window; w="$RW"
  rand 10
  # Reconnect-during-churn (op 9) exercises the control-mode reconnect
  # concurrency, a separate subsystem from sizing. CMUX_FUZZ_NO_RECONNECT
  # remaps it to a benign op so a run can isolate steady-state sizing
  # correctness from reconnect-race robustness. Default keeps op 9.
  if [ "${CMUX_FUZZ_NO_RECONNECT:-0}" = 1 ] && [ "$R" = 9 ]; then R=1; fi
  case $R in
    0) # pane resize, including starvation sizes down to 1 cell
      local pane; random_pane "$w"; pane="$RP"
      rand 2
      if [ "$R" = 0 ]; then
        rand 70; t resize-pane -t "$pane" -x $(( 1 + R )) 2>/dev/null
      else
        rand 24; t resize-pane -t "$pane" -y $(( 1 + R )) 2>/dev/null
      fi ;;
    1) # switch active window
      random_window; t select-window -t "$RW" ;;
    2) # split or kill — allowed all the way down to a single pane, so the
       # mirror's single↔multi pane lifecycle boundary gets crossed
      local count; count=$(t list-panes -t "$w" | wc -l | tr -d ' ')
      rand 2
      if [ "$count" -gt 1 ] && { [ "$count" -gt 5 ] || [ "$R" = 0 ]; }; then
        random_pane "$w"; t kill-pane -t "$RP" 2>/dev/null
      elif rand 2; [ "$R" = 0 ]; then
        t split-window -h -t "$w" "$RULER_COMMAND" 2>/dev/null
      else
        t split-window -v -t "$w" "$RULER_COMMAND" 2>/dev/null
      fi ;;
    3) # app window resize
      app_resize ;;
    4) # zoom toggle: the visible tree collapses to one pane and back
      random_pane "$w"; t resize-pane -Z -t "$RP" 2>/dev/null ;;
    5) # pane title rows top/bottom/off: either placement consumes a grid row
      rand 3
      case "$R" in
        0) t set-option -t $SESSION pane-border-status top 2>/dev/null ;;
        1) t set-option -t $SESSION pane-border-status bottom 2>/dev/null ;;
        *) t set-option -t $SESSION pane-border-status off 2>/dev/null ;;
      esac ;;
    6) # window churn: create a window or kill one (keep at least one)
      local wins; wins=$(t list-windows -t $SESSION | wc -l | tr -d ' ')
      rand 2
      if [ "$wins" -gt 2 ] || { [ "$wins" -gt 1 ] && [ "$R" = 0 ]; }; then
        random_window; t kill-window -t "$RW" 2>/dev/null
      else
        t new-window -t $SESSION "$RULER_COMMAND" 2>/dev/null
      fi ;;
    7) # container and assignment changing in the same instant
      local pane; random_pane "$w"; pane="$RP"
      rand 60; t resize-pane -t "$pane" -x $(( 5 + R )) 2>/dev/null &
      app_resize
      wait ;;
    8) # output flood while reflowing: the historical redraw-mangle recipe.
       # The flood gets its own short-lived pane — Ctrl-C into a ruler pane
       # would kill its redraw loop and leave stale wide text that looks
       # like a rendering bug on screen (it isn't; tmux rewraps history).
      local pane; random_pane "$w"; pane="$RP"
      t split-window -t "$w" "seq 1 20000; sleep 2" 2>/dev/null
      rand 50; t resize-pane -t "$pane" -x $(( 10 + R )) 2>/dev/null ;;
    9) # drop and re-establish the control connection (reseed + re-impose)
      "$CLI" workspace reconnect --workspace "$WORKSPACE_REF" >/dev/null 2>&1 ;;
  esac
}

# Find the mirror workspace by its session name, then SELECT it. Relying on
# ssh-tmux having focused it is not enough: an app restored with other
# workspaces can keep its old selection, every fuzz mirror stays hidden, and
# hidden mirrors are excluded from sizing_settled by design — the whole run
# judges nothing and passes vacuously. That happened; this is the fix.
WORKSPACE_REF=$("$CLI" list-workspaces 2>/dev/null \
  | awk -v s="$SESSION" '$0 ~ " " s "( |$)" {for (i = 1; i <= NF; i++) if ($i ~ /^workspace:/) { print $i; exit }}')
if [ "$DRY" != 1 ] && [ -z "${WINDOW_ID:-}" ]; then
  echo "FUZZ SETUP FAIL seed=$SEED: connect returned no window id ($CONNECT_OUT)"
  exit 98
fi
if [ "$DRY" != 1 ]; then
  if [ -z "$WORKSPACE_REF" ]; then
    echo "FUZZ SETUP FAIL seed=$SEED: no workspace mirroring session '$SESSION'" \
      "(have: $("$CLI" list-workspaces 2>/dev/null | tr '\n' ';'))"
    exit 98
  fi
  "$CLI" workspace select "$WORKSPACE_REF" >/dev/null 2>&1
  # Close THIS seed's mirror workspace on exit. The marathon runs seeds
  # against one long-lived app, and each seed's fresh-lab setup kills the
  # tmux server; a workspace left mounted from a prior seed then points at
  # a server that was killed and recreated with recycled window ids, and
  # its reconnect churns forever. One seed = one workspace, opened and
  # closed, so the gate measures steady-state sizing under churn rather
  # than reconnection to a stranger's recycled session (a separate
  # concern, tracked on its own). The shared cleanup trap closes it before
  # releasing a standalone lock and deleting this run's private ruler.
fi
# Inertness guard: a fuzzer that mutates nothing and reports green is worse
# than none (this happened — a subshell bug froze the RNG). Fingerprint the
# tmux layout every iteration; several identical fingerprints in a row with
# no debug-log growth means the ops aren't landing: fail loudly.
layout_fingerprint() {
  t list-panes -s -t $SESSION -F '#{window_name}:#{pane_id}:#{pane_width}x#{pane_height}' 2>/dev/null | md5 -q
}
inert=0
last_fp=""
last_size=0
for i in $(seq 1 "$ITERS"); do
  # Bursts: a third of iterations fire 2-3 mutations with no settle between,
  # racing the claim debounce against interleaved layout echoes.
  ops=1
  rand 3
  if [ "$R" = 0 ]; then rand 2; ops=$(( 2 + R )); fi
  for _ in $(seq 1 "$ops"); do do_op; done
  echo "iter=$i/$ITERS ops=$ops panes=$(t list-panes -s -t $SESSION 2>/dev/null | wc -l | tr -d ' ') windows=$(t list-windows -t $SESSION 2>/dev/null | wc -l | tr -d ' ') fails=$fail"
  if [ "$DRY" = 1 ]; then
    t list-windows -t $SESSION -F "iter=$i win=#{window_name} #{window_width}x#{window_height} panes=#{window_panes} zoom=#{window_zoomed_flag} layout=#{window_layout}" 2>/dev/null
    continue
  fi
  sleep "$SETTLE"
  check_iter "$i"
  fp=$(layout_fingerprint)
  size=$(stat -f%z "$DEBUG_LOG" 2>/dev/null || echo 0)
  if [ "$fp" = "$last_fp" ] && [ "$size" = "$last_size" ]; then
    inert=$((inert + 1))
    if [ "$inert" -ge 4 ]; then
      echo "FUZZ INERT seed=$SEED iter=$i: 4 iterations changed nothing — the fuzzer is not fuzzing"
      exit 97
    fi
  else
    inert=0
  fi
  last_fp=$fp
  last_size=$size
done

echo "FUZZ DONE seed=$SEED iters=$ITERS failures=$fail"
# Boolean exit: a raw count could wrap past 255 or collide with the
# reserved sentinel codes (97 inert, 98 setup, 99 hang). The count itself
# is in the FUZZ DONE line.
[ "$fail" -gt 0 ] && exit 1
exit 0
