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
# tmux ignores a TMUX_TMPDIR that does not exist and falls back to /tmp/tmux-$UID
# — the user's own default server, which this harness kills and resizes freely.
# The isolation is only real while the directory is there, so refuse to run
# rather than take the fallback silently.
[ -d "$TMPDIR_REMOTE" ] || {
  echo "ERROR: tmux socket dir does not exist: $TMPDIR_REMOTE" >&2
  echo "  tmux would silently fall back to the DEFAULT server (/tmp/tmux-$(id -u))." >&2
  echo "  Run scripts/remote-tmux-fuzz-host.sh first, or set CMUX_FUZZ_TMUX_TMPDIR." >&2
  exit 2
}
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
  # FUZZ_KEEP_STATE=1 leaves the workspace and remote server up so a failed
  # run's final state can be probed live (rpc pane_surfaces etc.) postmortem.
  if [ "$DRY" != 1 ] && [ -n "$WORKSPACE_REF" ] && [ "${FUZZ_KEEP_STATE:-0}" != 1 ]; then
    "$CLI" workspace close "$WORKSPACE_REF" >/dev/null 2>&1
  fi
  if [ "$FUZZ_SERVER_OWNED" = 1 ] && [ "${FUZZ_KEEP_STATE:-0}" != 1 ]; then
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
# Successful mirror->mirror switches. A seed that never managed one has not
# exercised the reveal path, and a green run would be reporting coverage it never
# delivered — the exact way this class stayed invisible.
OP10_SWITCHES=0
EVIDENCE_DIR="${CMUX_FUZZ_EVIDENCE_DIR:-}"

# The end-of-seed debug-log capture cannot cover a mid-seed failure: later
# iterations churn the log past the failure window before the seed ends
# (both stall captures from the last marathon held zero stall lines).
# Snapshot the tail at the moment of failure instead, one file per failure.
snapshot_debug_evidence() {
  [ -f "$DEBUG_LOG" ] || return 0
  if [ -z "$EVIDENCE_DIR" ]; then
    EVIDENCE_DIR=$(mktemp -d "$LOCAL_TMP_ROOT/cmux-remote-tmux-fuzz-evidence.XXXXXXXX") \
      || { EVIDENCE_DIR=""; return 0; }
    echo "evidence dir: $EVIDENCE_DIR"
  fi
  tail -600 "$DEBUG_LOG" > "$EVIDENCE_DIR/seed-$SEED-iter-$1-fail$fail-debuglog.txt" 2>/dev/null
}

note_fail() {
  echo "FUZZ FAIL seed=$SEED iter=$1: $2"
  fail=$((fail + 1))
  snapshot_debug_evidence "$1"
}

settlement_has_schema() {
  printf '%s' "$1" | jq -e '
    (.connected | type == "boolean") and (.windows | type == "array")
  ' >/dev/null 2>&1
}

# The reason a window is unsettled lives in its `why` terms, and the payload
# arrives pretty-printed: keeping its first few hundred characters spends the
# whole budget on indentation and stops inside the first window, which is how a
# settle failure came to be reported with no usable cause. Compact it and keep
# every window whole.
settlement_digest() {
  local digest
  # Keep the UNSETTLED windows, whole. The failure is "nothing settled in 8s", so
  # those windows are the entire cause, and bounding by window instead of by
  # character is what keeps the output parsable — a character cap cuts mid-token,
  # can drop the failing window's `why` outright depending on dictionary order,
  # and leaves behind something that is no longer JSON.
  # jq's status is honored: a payload of one valid value followed by garbage makes
  # jq print and then exit non-zero, which a discarded status would report as a
  # clean digest.
  if digest=$(printf '%s' "$1" | jq -ce '
        {connected, counters, windows: [.windows[]? | select(.settled != true)]}
      ' 2>/dev/null) && [ -n "$digest" ]; then
    printf '%s' "$digest"
    return
  fi
  # Reachable and worth distinguishing: an RPC that times out at second 8 arrives
  # here empty, and jq prints nothing for empty input. "The app stopped answering"
  # is a different failure from "the app answered, unsettled".
  printf 'unparsable or empty payload: %s' "$(printf '%s' "$1" | tr -d '\n' | cut -c1-300)"
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
    any(.windows[]?; ((.mismatches // []) | any(.[];
      test("rendered=|misplaced"))))
  ' >/dev/null 2>&1
}

settlement_is_unsettled() {
  printf '%s' "$1" | jq -e '
    .connected != true or any(.windows[]?; .settled != true)
  ' >/dev/null 2>&1
}

settlement_mismatch_lines() {
  printf '%s' "$1" | jq -r '
    [.windows[]?.mismatches[]?
      | select(test("rendered=|misplaced"))][0:4][]
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

# tmux pane id -> cmux surface id (plus whether that surface is on screen),
# from `remote.tmux.pane_surfaces`. This map is what makes the text oracle
# exact. Reading "the focused surface" cannot verify a NAMED pane: cmux does
# not follow tmux's active pane or current window, so `select-pane` then read
# returns whichever pane the app already showed — which matches the target's
# capture whenever the two panes happen to share dimensions (the ruler prints
# the same text at the same size) and mismatches when they do not. That read
# the wrong pane and reported it as a mirror defect.
PANE_SURFACES_JSON=""
refresh_pane_surfaces() {
  PANE_SURFACES_JSON=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.pane_surfaces \
    "{\"host\":\"$HOST\",\"session\":\"$SESSION\"}" 2>/dev/null) || return 1
  [ -n "$PANE_SURFACES_JSON" ] || return 1
  printf '%s' "$PANE_SURFACES_JSON" | jq -e '.panes' >/dev/null 2>&1
}

# The surface id rendering $1, only when that surface is on screen (a hidden
# tab holds its last render by design; judging it would report a designed lag).
surface_for_pane() {
  printf '%s' "$PANE_SURFACES_JSON" | jq -r --arg p "$1" '
    .panes[]? | select(.pane_id == $p and .on_screen == true) | .surface_id
  ' 2>/dev/null | head -1
}

# Panes the app is currently presenting, as tmux pane ids.
on_screen_panes() {
  printf '%s' "$PANE_SURFACES_JSON" | jq -r '
    .panes[]? | select(.on_screen == true) | .pane_id
  ' 2>/dev/null
}

capture_mirror_screen() {
  local surface=$1 raw text
  raw=$("$TIMEOUT_BIN" 8 "$CLI" rpc surface.read_text \
    "{\"surface_id\":\"$surface\"}" 2>/dev/null) || return 1
  text=$(printf '%s' "$raw" | jq -r '.result.text // .text // empty' 2>/dev/null) || return 1
  [ -n "$text" ] || return 1
  MIRROR_SCREEN=$(printf '%s\n' "$text" | normalize_screen)
}

compare_pane_screen() {
  local pane=$1 surface=$2 deadline before after
  deadline=$((SECONDS + 6))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if capture_remote_screen "$pane"; then
      before=$REMOTE_SCREEN
      if capture_mirror_screen "$surface" && capture_remote_screen "$pane"; then
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
  local iter=$1 panes pane surface checked remote_lines mirror_lines
  # Judge exactly the panes the app is PRESENTING, each against its OWN
  # surface. The app does not follow tmux's active pane or current window, so
  # the set of on-screen panes comes from the app itself, not from tmux.
  if ! refresh_pane_surfaces; then
    note_fail "$iter" "text oracle could not read remote.tmux.pane_surfaces"
    return
  fi
  panes=$(on_screen_panes)
  if [ -z "$panes" ]; then
    note_fail "$iter" "text oracle found no on-screen mirrored pane"
    return
  fi
  # The app chooses which panes it is presenting, so it also chooses this
  # oracle's coverage — a pane the app quietly omitted would drop out of the
  # comparison and the run would still read green. Hold the app to tmux's own
  # One workspace presents one tmux window at a time, so surfaces from two
  # windows on screen at once is a hidden tab drawing over the selected one.
  # The per-window census below cannot see this: each window individually
  # matches tmux while both are visible.
  on_screen_windows=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r '
    [.panes[]? | select(.on_screen == true) | .window_id] | unique | join(" ")
  ' 2>/dev/null)
  if [ "$(printf '%s\n' $on_screen_windows | grep -c .)" -gt 1 ]; then
    # Same re-read discipline as every other judge: a probe can land inside
    # the one-frame handoff of a tab switch, and only a state that persists
    # through a fresh census is a defect.
    # Judging the stale snapshot again would just repeat the first read, so
    # a failed refresh defers the verdict to the next iteration entirely.
    if ! refresh_pane_surfaces; then
      return
    fi
    panes=$(on_screen_panes)
    [ -n "$panes" ] || return
    on_screen_windows=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r '
      [.panes[]? | select(.on_screen == true) | .window_id] | unique | join(" ")
    ' 2>/dev/null)
    if [ "$(printf '%s\n' $on_screen_windows | grep -c .)" -gt 1 ]; then
      note_fail "$iter" "overlay: surfaces from multiple windows on screen at once [$on_screen_windows]"
    fi
  fi
  # census: a window with an on-screen pane is the one the app is showing, so
  # every pane tmux DRAWS for it must be on screen too. A missing pane is the app
  # failing to render a pane of the visible window, which is a defect, not less
  # coverage.
  #
  # "Draws" is the load-bearing word, and `list-panes` cannot answer it. Zoom
  # hides panes without closing them, so list-panes reports the whole base tree
  # for a zoomed window just as it does for an unzoomed one. tmux draws only the
  # zoomed pane, and the app matches that by design (renderedLayout is
  # visibleLayout ?? layout, so only the zoomed leaf reaches the bonsplit tree
  # while its siblings stay alive and unrendered). Taking list-panes as the
  # expected set therefore reports every sibling of a zoomed pane as dropped
  # coverage — all panes but one, on every iteration a zoomed window is visible.
  # Gate on window_zoomed_flag and expect the zoomed pane by itself.
  for window in $on_screen_windows; do
    window_panes=$(t list-panes -t "$window" \
      -F '#{window_zoomed_flag} #{pane_active} #{pane_id}' 2>/dev/null)
    if [ -z "$window_panes" ]; then
      # The app says it is SHOWING this window and tmux does not have it. Skipping
      # here was the quiet path: another visible window's successful comparison
      # keeps `checked` non-zero, so the iteration passes while the window whose
      # panes are stale on screen is compared against nothing at all. If the app
      # shows a window tmux has closed, that is the finding.
      note_fail "$iter" "visible $window: the app shows it but tmux has no panes for it (window gone, mirror still on screen)"
      continue
    fi
    zoom_state=off
    if printf '%s\n' "$window_panes" | grep -q '^1 '; then
      zoom_state=on
      tmux_panes=$(printf '%s\n' "$window_panes" | awk '$2 == 1 { print $3 }' | sort)
    else
      tmux_panes=$(printf '%s\n' "$window_panes" | awk '{ print $3 }' | sort)
    fi
    app_panes=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r --arg w "$window" '
      .panes[]? | select(.window_id == $w and .on_screen == true) | .pane_id
    ' 2>/dev/null | sort)
    # BOTH directions. Panes tmux draws that the app lacks drop coverage; panes the
    # app shows that tmux does not draw are overdraw — and the zoom gate narrows the
    # expected set precisely in that direction, so checking only the first half turns
    # "the app kept painting a zoomed pane's siblings" into a silent pass. Same fault
    # the one-sided census had, just pointed the other way.
    missing=$(comm -23 <(printf '%s\n' "$tmux_panes") <(printf '%s\n' "$app_panes") | tr '\n' ' ')
    unexpected=$(comm -13 <(printf '%s\n' "$tmux_panes") <(printf '%s\n' "$app_panes") | tr '\n' ' ')
    if [ -n "${missing// /}${unexpected// /}" ]; then
      # The app census came from the earlier pane_surfaces snapshot; a zoom
      # toggle between that snapshot and the reads above manufactures a
      # difference out of two individually consistent states. Confirm against
      # fresh state on BOTH sides before recording a defect; only a difference
      # that survives the re-read is one.
      if ! refresh_pane_surfaces; then
        return
      fi
      panes=$(on_screen_panes)
      [ -n "$panes" ] || return
      window_still_on_screen=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r --arg w "$window" '
        any(.panes[]?; .window_id == $w and .on_screen == true)
      ' 2>/dev/null)
      if [ "$window_still_on_screen" != "true" ]; then
        continue
      fi
      window_panes=$(t list-panes -t "$window" \
        -F '#{window_zoomed_flag} #{pane_active} #{pane_id}' 2>/dev/null) || continue
      zoom_state=off
      if printf '%s\n' "$window_panes" | grep -q '^1 '; then
        zoom_state=on
        tmux_panes=$(printf '%s\n' "$window_panes" | awk '$2 == 1 { print $3 }' | sort)
      else
        tmux_panes=$(printf '%s\n' "$window_panes" | awk '{ print $3 }' | sort)
      fi
      app_panes=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r --arg w "$window" '
        .panes[]? | select(.window_id == $w and .on_screen == true) | .pane_id
      ' 2>/dev/null | sort)
      missing=$(comm -23 <(printf '%s\n' "$tmux_panes") <(printf '%s\n' "$app_panes") | tr '\n' ' ')
      unexpected=$(comm -13 <(printf '%s\n' "$tmux_panes") <(printf '%s\n' "$app_panes") | tr '\n' ' ')
      if [ -n "${missing// /}${unexpected// /}" ]; then
        # Both sides and the zoom flag, not just the difference: whether a pane is
        # expected on screen turns entirely on zoom, so naming the odd pane alone
        # accuses the app in a sentence that reads identically when the harness is the
        # one that is wrong.
        note_fail "$iter" "visible $window: pane census differs missing=[$missing] unexpected=[$unexpected] zoom=$zoom_state expected=[$(printf '%s' "$tmux_panes" | tr '\n' ' ')] app_on_screen=[$(printf '%s' "$app_panes" | tr '\n' ' ')]"
      fi
    fi
  done
  checked=0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    surface=$(surface_for_pane "$pane")
    if [ -z "$surface" ]; then
      note_fail "$iter" "text oracle has no on-screen surface for pane $pane"
      continue
    fi
    # The pane may have been killed by the churn between the map read and now.
    t list-panes -t "$pane" -F '#{pane_id}' >/dev/null 2>&1 || continue
    checked=$((checked + 1))
    if compare_pane_screen "$pane" "$surface"; then
      continue
    fi
    note_fail "$iter" "pane $pane mirror surface $surface differs from tmux capture-pane"
    remote_lines=$(printf '%s\n' "$REMOTE_SCREEN" | grep -c . || true)
    mirror_lines=$(printf '%s\n' "$MIRROR_SCREEN" | grep -c . || true)
    echo "  text evidence pane=$pane remote_lines=$remote_lines mirror_lines=$mirror_lines"
    # Is the surface the size tmux assigned it? A content miss with a MATCHING
    # grid is lost/stale output; a content miss with a SHORT grid is a sizing
    # miss the grid oracle should have caught. Print both so the failure names
    # which, instead of leaving it to inference (the ruler's lines are all
    # identical, so the diff cannot say which line went missing).
    echo "  tmux pane geometry: $(t display-message -p -t "$pane" '#{pane_width}x#{pane_height} win=#{window_width}x#{window_height} border=#{pane-border-status} zoom=#{window_zoomed_flag}' 2>/dev/null)"
    echo "  tmux list-panes (id WxH top): $(t list-panes -t "$pane" -F '#{pane_id}=#{pane_width}x#{pane_height}@#{pane_top}' 2>/dev/null | tr '\n' ' ')"
    echo "  app assigned (all panes of the window):"
    "$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.pane_grids \
      "{\"host\":\"$HOST\",\"session\":\"$SESSION\"}" 2>/dev/null \
      | jq -r --arg p "$pane" '
          .windows[]? | select(.panes[]?.pane_id == $p)
          | .panes[] | "    \(.pane_id)=\(.assigned.cols)x\(.assigned.rows) rendered=\(.rendered.cols // "?")x\(.rendered.rows // "?")"
        ' 2>/dev/null || true
    "$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.pane_grids \
      "{\"host\":\"$HOST\",\"session\":\"$SESSION\"}" 2>/dev/null \
      | jq -c --arg p "$pane" '
          .windows[]? | select(.panes[]?.pane_id == $p)
          | {win: .window_id, base, pushed, zoomed, visible: .visible_for_sizing,
             pane: (.panes[] | select(.pane_id == $p) | {assigned, rendered, match})}
        ' 2>/dev/null | sed 's/^/  pane_grids: /' || true
    diff -u \
      <(printf '%s\n' "$REMOTE_SCREEN") \
      <(printf '%s\n' "$MIRROR_SCREEN") \
      | head -40 | sed 's/^/  /' || true
  done <<< "$panes"
  if [ "$checked" -eq 0 ]; then
    note_fail "$iter" "text oracle checked no pane (every on-screen pane vanished mid-check)"
  fi
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
# Every line carries this pane's OWN id (tmux exports TMUX_PANE into the pane's
# environment) as well as its size. Without the id, two panes of equal
# dimensions print byte-identical screens, so a comparison that read the wrong
# pane's surface would pass — which is exactly how a broken text oracle stayed
# green. With the id, a wrong surface can never alias a right one.
unset COLUMNS LINES
id=${TMUX_PANE:-%?}
while :; do
  sz=$(stty size 2>/dev/null); rows=${sz%% *}; cols=${sz##* }
  [ -n "$rows" ] || rows=24; [ -n "$cols" ] || cols=80
  base=$(printf '%0.s0123456789' $(seq 1 400))
  printf '\033[2J\033[H'
  r=1
  while [ "$r" -lt "$rows" ]; do
    printf '%s\n' "$(printf '%s %03dx%03d %s' "$id" "$cols" "$rows" "$base" | cut -c1-"$cols")"
    r=$((r+1))
  done
  printf 'END %s %03dx%03d' "$id" "$cols" "$rows"
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
  # guessing with a timer. The budget is a hard 8 seconds: a healthy full
  # cycle (claim → tmux layout → imposition → rendered frames) settles in
  # about 0.4s, so a window still unsettled at 8s is a liveness defect. The
  # old ladder here (10x2s poll + 15x2s reconfirm, up to 50s) existed to
  # avoid misreading transitions — and instead it hid stalls the app took
  # tens of seconds to argue its way out of.
  local settle_start=$SECONDS settled_json="" budget=8 settled=0
  while :; do
    settled_json=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.sizing_settled 2>/dev/null)
    # A failed or timed-out RPC has no windows KEY at all — that is absence
    # of evidence, not settledness. Keep polling inside the budget.
    if ! settlement_has_schema "$settled_json"; then
      :
    # An EMPTY window list is settled only when there is genuinely nothing
    # to judge: the visible tab mirrors a single-pane window. If the lab's
    # active window has several panes, empty means the fuzz mirror is not
    # the visible workspace — the gate would be blind, so re-select it and
    # keep polling; exhausting the budget then reports the failure.
    elif ! settlement_has_reported_windows "$settled_json"; then
      local active_panes
      active_panes=$(t display -t $SESSION -p '#{window_panes}' 2>/dev/null || echo 1)
      if [ "${active_panes:-1}" -le 1 ]; then
        settled=1
        break
      fi
      "$CLI" workspace select "$WORKSPACE_REF" >/dev/null 2>&1
    # A pane with no sizing sample yet is still in transition even when the
    # window's claim/layout dims agree — keep polling until every pane has
    # reported. A rendered-grid mismatch does NOT block the break: a pane
    # wrong AT settle is exactly the bug this harness exists to capture,
    # and waiting it out would misreport it as "never settled".
    elif settlement_ready "$settled_json"; then
      settled=1
      break
    fi
    if [ $((SECONDS - settle_start)) -ge "$budget" ]; then
      break
    fi
    sleep 1
  done
  echo "  settle $((SECONDS - settle_start))s (iter $iter)"
  if [ "$settled" != 1 ]; then
    note_fail "$iter" "settle exceeded ${budget}s budget (healthy baseline ~0.4s): $(settlement_digest "$settled_json")"
  elif settlement_has_render_mismatch "$settled_json"; then
    # Mismatch WHILE settled: re-read twice before failing, so a probe that
    # raced the last frame of a transition cannot manufacture a defect.
    # Only a state that stays wrong is one.
    rc_tries=0
    while [ "$rc_tries" -lt 2 ]; do
      sleep 1
      settled_json=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.sizing_settled 2>/dev/null)
      if settlement_clean "$settled_json"; then
        echo "  reconfirm: mismatch cleared after $((rc_tries + 1))s (iter $iter)"
        break
      fi
      rc_tries=$((rc_tries + 1))
    done
    if ! settlement_clean "$settled_json"; then
      note_fail "$iter" "settled with pane mismatches (persisted through reconfirm):"
      settlement_mismatch_lines "$settled_json" | sed 's/^/  /'
    fi
  fi
  # Oracle 2: select every pane in the settled visible tmux window and compare
  # the mirror's actual terminal text with tmux's capture. This crosses the
  # control connection, pane-focus routing, Ghostty surface, and debug CLI;
  # sizing_settled alone cannot detect content corruption along that path.
  if settlement_has_schema "$settled_json" && ! settlement_is_unsettled "$settled_json"; then
    check_screen_oracle "$iter"
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

# Switch the cmux TAB to a different mirrored window.
#
# Op 1's `select-window` cannot reach this: cmux never follows tmux's current
# window, so a tmux-side switch changes nothing about which tab is on screen.
# Until this op existed the fuzz had never once switched a mirror tab — which is
# exactly where the workspace reuses the mounted view and swaps the mirror
# underneath it, so every change-gated visibility edge is dead and the newly
# selected window must re-derive its own container. That whole class was
# unreachable from here while the marathon read green.
#
# `surface.focus` is the same route a user's click takes
# (ControlCommandCoordinator -> Workspace.focusPanel -> bonsplitController.selectTab);
# a back-door that reconstructed the view would fire the very edge under test.
switch_mirror_tab() {
  local iter=$1
  refresh_pane_surfaces || return 0
  # MIRRORED windows only. pane_surfaces lists single-pane windows too, and those
  # have no mirror — focusing one exercises mirror->ordinary-panel, not the
  # mirror->mirror reveal this op exists for, and would report success for it.
  # pane_grids lists exactly the mirrored windows.
  local grids mirrored shown target
  grids=$("$TIMEOUT_BIN" 8 "$CLI" rpc remote.tmux.pane_grids \
    "{\"host\":\"$HOST\",\"session\":\"$SESSION\"}" 2>/dev/null) || return 0
  mirrored=$(printf '%s' "$grids" | jq -r '[.windows[]?.window_id] | join(" ")' 2>/dev/null)
  [ -n "$mirrored" ] || return 0
  # Demand exactly one on-screen window, not panes[0]'s window: during an
  # overlapping tab handoff two windows are briefly on screen at once and [0]
  # could name either of them.
  shown=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r '
    [.panes[] | select(.on_screen == true) | .window_id] | unique
    | if length == 1 then .[0] else empty end' 2>/dev/null)
  # A vacuous landing check is worse than none: without a single shown window,
  # any window appearing later "differs" and the op would claim it proved a
  # switch it cannot attribute.
  if [ -z "$shown" ]; then
    echo "  (op10 skipped: zero or several windows on screen; no clean start state)"
    return 0
  fi
  case " $mirrored " in *" $shown "*) : ;; *)
    echo "  (op10 skipped: shown window @$shown is not mirrored)"; return 0 ;;
  esac
  # Take the target's WINDOW beside its surface. "Some other mirrored window is
  # shown now" is not proof this op switched to the one it asked for: with a third
  # mirrored window in play, or any concurrent selection, the shown window can
  # differ from where it started without the target ever being selected, and the
  # counter would bank a switch that never landed — a coverage number reporting
  # more than it delivered, which is the fault this op exists to remove.
  # Exact membership, not `inside`: jq's `inside` compares strings by containment,
  # so ["@3"] | inside(["@30","@1"]) is true — once tmux hands out @10 and up
  # (routine across a marathon) @1 would pass as mirrored on the strength of @10,
  # and the op would "switch" to a window it never verified was a mirror.
  local target_window mirrored_json
  mirrored_json=$(printf '%s' "$grids" | jq -c '[.windows[]?.window_id]' 2>/dev/null) || return 0
  target=$(printf '%s' "$PANE_SURFACES_JSON" | jq -r \
    --arg shown "$shown" --argjson mir "$mirrored_json" '
    [.panes[]
       | select(.on_screen == false)
       | select((.window_id | tostring) != $shown)
       | select(.window_id | IN($mir[]))][0]
    | "\(.surface_id // "") \(.window_id // "")"' 2>/dev/null)
  target_window=${target#* }
  target=${target%% *}
  if [ -z "$target" ] || [ -z "$target_window" ] || [ "$target" = "null" ]; then
    echo "  (op10 skipped: no second MIRRORED window to switch to)"
    return 0
  fi
  "$TIMEOUT_BIN" 8 "$CLI" rpc surface.focus "{\"surface_id\":\"$target\"}" >/dev/null 2>&1 || {
    note_fail "$iter" "op10: surface.focus rejected $target (mirror->mirror switch never attempted)"
    return 0
  }
  # Prove the TARGET window is the one now shown. Bounded tightly: a wedged
  # socket must reach the hang detector, not idle here for a minute. Probe before
  # sleeping so an immediate switch costs nothing.
  local after
  for _ in 1 2 3 4 5 6; do
    if "$TIMEOUT_BIN" 3 "$CLI" rpc remote.tmux.pane_surfaces \
      "{\"host\":\"$HOST\",\"session\":\"$SESSION\"}" > "$RUN_DIR/op10.json" 2>/dev/null; then
      # Same singleton rule as the start state: the landing only counts once
      # the target is the ONLY on-screen window. Mid-handoff, target-plus-old
      # is still on screen and must keep polling, not bank the switch early.
      after=$(jq -r '
        [.panes[] | select(.on_screen == true) | .window_id] | unique
        | if length == 1 then .[0] else "\(length) windows: \(join(","))" end' \
        "$RUN_DIR/op10.json" 2>/dev/null)
      if [ -n "$after" ] && [ "$after" = "$target_window" ]; then
        OP10_SWITCHES=$((OP10_SWITCHES + 1))
        rm -f "$RUN_DIR/op10.json"
        return 0
      fi
    fi
    sleep 0.5
  done
  rm -f "$RUN_DIR/op10.json"
  note_fail "$iter" "op10: focused $target but the shown window is ${after:-none}, not solely the target @$target_window (was @$shown) — the mirror tab never switched to it"
}

do_op() {
  local iter=${1:-0}
  local w
  random_window; w="$RW"
  rand 11
  # Reconnect-during-churn (op 9) exercises the control-mode reconnect
  # concurrency, a separate subsystem from sizing. CMUX_FUZZ_NO_RECONNECT
  # remaps it to a benign op so a run can isolate steady-state sizing
  # correctness from reconnect-race robustness. Default keeps op 9.
  if [ "${CMUX_FUZZ_NO_RECONNECT:-0}" = 1 ] && [ "$R" = 9 ]; then R=1; fi
  # Record the op behind each iteration. Without it a failure names an iteration
  # and nothing else, and the first question about any fuzz failure — which
  # operation produced this state — can only be answered by re-running the seed
  # and counting by hand.
  OPS_THIS_ITER="${OPS_THIS_ITER:+$OPS_THIS_ITER,}op$R"
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
    6) # window churn: create a window or kill one.
       #
       # Biases toward keeping TWO MULTI-pane windows alive, because only
       # multi-pane windows get a mirror: with fewer than two of them op 10 has no
       # mirror->mirror switch to make and silently tests nothing, which is how the
       # reveal path stayed unexercised while this harness reported green. A fresh
       # window is split immediately for the same reason — an unsplit one is not
       # mirrored.
       #
       # This is a BIAS, not a guarantee, and the difference matters: op 2 kills
       # panes and can collapse both mirrors to single panes on its own, so a run
       # can still reach multi<2 between op-6 draws. op 10 says so out loud when it
       # skips rather than reporting silent coverage — that log line is the real
       # safeguard here, not this arithmetic.
      local multi; multi=$(t list-windows -t $SESSION -F '#{window_panes}' 2>/dev/null \
        | awk '$1 > 1' | wc -l | tr -d ' ')
      rand 2
      if [ "${multi:-0}" -gt 2 ] && [ "$R" = 0 ]; then
        random_window; t kill-window -t "$RW" 2>/dev/null
      else
        # Re-split an existing single-pane window when we are short of mirrors,
        # rather than only ever adding new windows: op 2 flattens the ones we have.
        if [ "${multi:-0}" -lt 2 ]; then
          local flat
          flat=$(t list-windows -t $SESSION -F '#{window_panes} #{window_id}' 2>/dev/null \
            | awk '$1 == 1 { print $2; exit }')
          if [ -n "$flat" ]; then
            t split-window -h -t "$flat" "$RULER_COMMAND" 2>/dev/null
            return 0
          fi
        fi
        t new-window -t $SESSION "$RULER_COMMAND" 2>/dev/null
        t split-window -h -t $SESSION "$RULER_COMMAND" 2>/dev/null
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
    10) # switch the cmux TAB (mirror->mirror), which op 1 cannot do
      switch_mirror_tab "$iter" ;;
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
  OPS_THIS_ITER=""
  for _ in $(seq 1 "$ops"); do do_op "$i"; done
  echo "iter=$i/$ITERS ops=$ops [$OPS_THIS_ITER] panes=$(t list-panes -s -t $SESSION 2>/dev/null | wc -l | tr -d ' ') windows=$(t list-windows -t $SESSION 2>/dev/null | wc -l | tr -d ' ') fails=$fail"
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

# A seed that never switched a mirror tab did not exercise the reveal path, so its
# green says nothing about the class this op exists for — and silent zero coverage
# reading as a pass is exactly how a real mirror bug survived 125 "clean"
# iterations. But whether a seed DRAWS op 10 is a property of the RNG, not of the
# code under test: with one op in eleven and about 37 draws in a 25-iteration seed,
# roughly one seed in thirty never draws it at all, and a shorter run far more
# often. Counting that as a defect would file "the dice went another way" next to
# real failures, and a gate that cries wolf gets ignored.
#
# So it is not a `fail`. It reports on its own line, and the marathon asserts the
# floor across seeds, where the draw actually has room to even out.
echo "FUZZ COVERAGE seed=$SEED op10_switches=${OP10_SWITCHES:-0}"
if [ "${OP10_SWITCHES:-0}" -eq 0 ]; then
  echo "FUZZ UNCOVERED seed=$SEED: no mirror->mirror tab switch landed in $ITERS iterations" \
    "(op10 never drew, or never had two mirrored windows) — this seed says nothing about the reveal path"
fi
echo "FUZZ DONE seed=$SEED iters=$ITERS failures=$fail op10_switches=${OP10_SWITCHES:-0}"
# Boolean exit: a raw count could wrap past 255 or collide with the
# reserved sentinel codes (97 inert, 98 setup, 99 hang). The count itself
# is in the FUZZ DONE line.
[ "$fail" -gt 0 ] && exit 1
exit 0
