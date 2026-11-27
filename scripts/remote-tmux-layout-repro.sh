#!/bin/bash
# ============================================================================
# Remote-tmux multi-pane layout repro.
#
# Builds a local tmux server under an ownership lock, mirrors it through a
# tagged Debug cmux app, then checks:
#   1. every pane's mirrored read-screen text matches `capture-pane -p -J`
#   2. each tmux window's size stays fixed across five 2-second samples
#
# No real remote host is required, but the tagged app must be launched with the
# checked-in ssh shim and the same TMUX_TMPDIR so its ssh-tmux transport reaches
# this local lab server:
#
#   CMUX_REMOTE_TMUX_SSH_FOR_TESTING=$PWD/scripts/remote-tmux-e2e-ssh-shim.sh
#   TMUX_TMPDIR=/tmp/cmux-max1
#
# Override both the app and this script with CMUX_LAYOUT_TMUX_TMPDIR when two
# tagged repro environments need to run side by side.
#
# Exit code is the number of failing checks (0 = all green). Setup/precondition
# failures exit 2.
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CMUX_TAG:?set CMUX_TAG to the tagged debug app (e.g. CMUX_TAG=tmux-layout)}"

HOST="cmux-max1"
SESSION="cmux-max1"
SRVDIR="${CMUX_LAYOUT_TMUX_TMPDIR:-/tmp/cmux-max1}"
SHIM="$REPO/scripts/remote-tmux-e2e-ssh-shim.sh"
SETTLE_SECONDS="${CMUX_LAYOUT_SETTLE_SECONDS:-5}"
TMUXBIN="${CMUX_LAYOUT_TMUX:-}"
CMUX_FUZZ_LOCK_DIR="${SRVDIR}.layout-repro.lock"
CMUX_FUZZ_LOCK_OWNED=0
SRV_OWNED=0

. "$REPO/scripts/remote-tmux-fuzz-lock.sh"

UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || {
  echo "ERROR: neither 'timeout' nor 'gtimeout' found; install GNU coreutils (brew install coreutils)" >&2
  exit 2
}

PYTHON_BIN="$(command -v python3 || true)"
[ -n "$PYTHON_BIN" ] || {
  echo "ERROR: python3 is required for parsing cmux JSON output" >&2
  exit 2
}

if [ -z "$TMUXBIN" ]; then
  for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    if [ -x "$candidate" ]; then TMUXBIN="$candidate"; break; fi
  done
fi
[ -n "$TMUXBIN" ] || {
  echo "ERROR: tmux not found at /opt/homebrew/bin/tmux, /usr/local/bin/tmux, or /usr/bin/tmux" >&2
  exit 2
}

[ -x "$SHIM" ] || {
  echo "ERROR: missing executable ssh shim: $SHIM" >&2
  exit 2
}

wait_until() { # $1=timeout_s, $2..=predicate command
  local timeout_s="$1"; shift
  local deadline=$((SECONDS + timeout_s))
  until "$@"; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

srv() {
  (unset TMUX; TMUX_TMPDIR="$SRVDIR" "$TMUXBIN" "$@")
}

cli() {
  CMUX_TAG="$CMUX_TAG" "$TIMEOUT_BIN" 90 "$REPO/scripts/cmux-debug-cli.sh" "$@" 2>&1
}

norm() {
  sed 's/[[:space:]]*$//' | awk '{a[NR]=$0} END{last=NR; while(last>0 && a[last]=="") last--; for(i=1;i<=last;i++) print a[i]}'
}

remote_visible() {
  srv capture-pane -p -J -t "$1" 2>/dev/null | norm
}

mirror_visible() {
  cli read-screen --window "$MIRROR_WINDOW" 2>/dev/null | norm
}

srv_down() {
  ! srv list-sessions >/dev/null 2>&1
}

reset_srv() {
  mkdir -p "$SRVDIR"
  if ! srv_down; then
    echo "ERROR: tmux server already exists under $SRVDIR; refusing to kill an unowned lab" >&2
    return 1
  fi
}

ruler_command() {
  local width="$1"
  printf "%s" "CMUX_RULER_WIDTH=$width /bin/sh -c 'w=\${CMUX_RULER_WIDTH:-80}; printf \"RULER\\n\"; i=1; while [ \"\$i\" -le \"\$w\" ]; do printf \"%d\" \$((i % 10)); i=\$((i + 1)); done; printf \"\\n\"; exec sleep 3600'"
}

pane_has_ruler() {
  srv capture-pane -p -t "$1" 2>/dev/null | grep -q '^RULER$'
}

run_ruler_in_pane() {
  local pane="$1" width command
  width="$(srv display-message -p -t "$pane" '#{pane_width}' 2>/dev/null)" || return 1
  command="$(ruler_command "$width")"
  srv respawn-pane -k -t "$pane" "$command" >/dev/null || return 1
  wait_until 8 pane_has_ruler "$pane"
}

run_rulers() {
  local pane
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    run_ruler_in_pane "$pane" || {
      echo "ERROR: ruler did not paint in $pane" >&2
      return 1
    }
  done < <(srv list-panes -s -t "$SESSION" -F '#{pane_id}')
}

build_sixcol() {
  local panes=()
  local widths i observed pane
  srv new-session -d -s "$SESSION" -x 154 -y 30 -n sixcol >/dev/null || return 1
  for _ in 1 2 3 4 5; do
    srv split-window -h -t "$SESSION:sixcol" >/dev/null || return 1
  done
  srv select-layout -t "$SESSION:sixcol" even-horizontal >/dev/null || return 1

  while IFS= read -r pane; do
    [ -n "$pane" ] && panes+=("$pane")
  done < <(srv list-panes -t "$SESSION:sixcol" -F '#{pane_id}')
  widths=(30 20 12 38 25 24)
  [ "${#panes[@]}" -eq 6 ] || return 1
  for _ in 1 2; do
    for i in "${!widths[@]}"; do
      srv resize-pane -t "${panes[$i]}" -x "${widths[$i]}" >/dev/null || return 1
    done
  done
  observed="$(srv list-panes -t "$SESSION:sixcol" -F '#{pane_width}' | paste -sd/ -)"
  echo "sixcol pane widths: $observed"
}

build_deep() {
  local target direction percent
  srv new-window -t "$SESSION" -n deep >/dev/null || return 1
  target="$(srv list-panes -t "$SESSION:deep" -F '#{pane_id}' | head -1)"
  while IFS=: read -r direction percent; do
    target="$(srv split-window "$direction" -p "$percent" -P -F '#{pane_id}' -t "$target")" || return 1
  done <<'EOF'
-h:63
-v:58
-h:52
-v:47
-h:41
EOF
  echo "deep panes: $(srv list-panes -t "$SESSION:deep" -F '#{pane_id}' | paste -sd' ' -)"
}

build_lab() {
  reset_srv
  build_sixcol || return 1
  build_deep || return 1
  srv select-window -t "$SESSION:sixcol" >/dev/null || return 1
  run_rulers || return 1
}

window_ids() {
  cli list-windows | awk '{for(i=1;i<=NF;i++) if($i ~ /^selected_workspace=/ && $(i-1) ~ /'"$UUID"'/) print $(i-1)}'
}

attach_mirror() {
  local output status
  echo "Attaching with: CMUX_TAG=$CMUX_TAG scripts/cmux-debug-cli.sh ssh-tmux $HOST"
  output="$(cli ssh-tmux "$HOST")"
  status=$?
  printf '%s\n' "$output"
  [ "$status" -eq 0 ] || return "$status"
  MIRROR_WINDOW="$(printf '%s\n' "$output" | awk -F'window=' '/^OK host=/{split($2,a," "); print a[1]; exit}')"
  if [ -z "$MIRROR_WINDOW" ]; then
    # Fallback for older CLI output: pick the key/newest cmux window.
    MIRROR_WINDOW="$(window_ids | tail -1)"
  fi
  [ -n "$MIRROR_WINDOW" ]
}

panel_id_for_title() {
  local title="$1"
  cli --json list-panels --window "$MIRROR_WINDOW" 2>/dev/null | "$PYTHON_BIN" -c '
import json, sys
title = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for item in data.get("surfaces", []):
    if item.get("title") == title:
        value = item.get("ref") or item.get("pane_ref")
        if value:
            print(value)
            sys.exit(0)
sys.exit(1)
' "$title"
}

focus_tab() {
  local title="$1" panel deadline
  deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    panel="$(panel_id_for_title "$title" 2>/dev/null || true)"
    if [ -n "$panel" ]; then
      cli focus-panel --window "$MIRROR_WINDOW" --panel "$panel" >/dev/null && return 0
    fi
    sleep 0.4
  done
  return 1
}

R=""
M=""
compare_pane_settled() {
  local pane="$1" deadline
  deadline=$((SECONDS + 20))
  while :; do
    srv select-pane -t "$pane" >/dev/null 2>&1 || true
    R="$(remote_visible "$pane" || true)"
    M="$(mirror_visible || true)"
    if [ -n "$R" ] && [ "$R" = "$M" ]; then
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.5
  done
}

PASS=0
FAIL=0
FAILED=""

record_pass() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

record_fail() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED $1"
  echo "  FAIL  $1"
}

compare_window_panes() {
  local window_name="$1" pane label
  if ! focus_tab "$window_name"; then
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      record_fail "$window_name/$pane(no-tab)"
    done < <(srv list-panes -t "$SESSION:$window_name" -F '#{pane_id}')
    return
  fi

  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    label="$window_name/$pane"
    if compare_pane_settled "$pane"; then
      record_pass "$label content"
    else
      record_fail "$label content"
      echo "        remote=$(printf '%s' "$R" | grep -c .) non-blank lines  mirror=$(printf '%s' "$M" | grep -c .) non-blank lines"
      paste <(printf '%s\n' "$R" | cat -n) <(printf '%s\n' "$M" | cat -n) | head -10 | sed 's/^/        /'
    fi
  done < <(srv list-panes -t "$SESSION:$window_name" -F '#{pane_id}')
}

window_size() {
  srv display-message -p -t "$SESSION:$1" '#{window_width}x#{window_height}' 2>/dev/null
}

check_window_stability() {
  local window_name="$1" first="" size="" changed=0 samples=() i
  for i in 1 2 3 4 5; do
    size="$(window_size "$window_name" || true)"
    samples+=("$size")
    if [ -z "$first" ]; then
      first="$size"
    elif [ "$size" != "$first" ]; then
      changed=1
    fi
    [ "$i" -lt 5 ] && sleep 2
  done
  if [ "$changed" -eq 0 ] && [ -n "$first" ]; then
    record_pass "$window_name stable ${samples[*]}"
  else
    record_fail "$window_name size-changed ${samples[*]}"
  fi
}

cleanup() {
  if [ "$SRV_OWNED" = 1 ] && [ "${CMUX_LAYOUT_KEEP_TMUX:-0}" != "1" ]; then
    srv kill-server >/dev/null 2>&1 || true
  fi
  cmux_fuzz_lock_release
}
trap cleanup EXIT

cmux_fuzz_lock_acquire "$(dirname "$SRVDIR")" || exit 2
reset_srv || exit 2
SRV_OWNED=1

echo "=== remote-tmux layout repro  tag=$CMUX_TAG host=$HOST tmux_tmpdir=$SRVDIR ==="
echo "Expected tagged app env: CMUX_REMOTE_TMUX_SSH_FOR_TESTING=$SHIM  TMUX_TMPDIR=$SRVDIR"

build_lab || {
  echo "ERROR: failed to build isolated tmux lab under $SRVDIR" >&2
  exit 2
}

attach_mirror || {
  cat >&2 <<EOF
ERROR: ssh-tmux attach failed.

The tagged app must already be running with:
  CMUX_REMOTE_TMUX_SSH_FOR_TESTING=$SHIM
  TMUX_TMPDIR=$SRVDIR

Then rerun:
  CMUX_TAG=$CMUX_TAG $0
EOF
  exit 2
}

echo "mirror window: $MIRROR_WINDOW"
echo "settling ${SETTLE_SECONDS}s before checks..."
sleep "$SETTLE_SECONDS"

compare_window_panes sixcol
compare_window_panes deep
check_window_stability sixcol
check_window_stability deep

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -gt 0 ] && echo "FAILED:$FAILED"
exit "$FAIL"
