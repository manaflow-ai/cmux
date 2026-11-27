#!/usr/bin/env bash
# Apple Screen Sharing.app target. The wrapper targets apple-high and
# apple-standard set EVAL_APPLE_MODE before invoking this file.
set -euo pipefail
verb=$1
shift
mode=${EVAL_APPLE_MODE:-high}
host=${EVAL_PEER:-${EVAL_APPLE_HOST:-127.0.0.1}}

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

# received_bytes PID: the process's cumulative received bytes, all its sockets, from nettop's one
# sample (`time,PROCESS.PID,BYTES_IN,`), the way gui-viewer.sh counts a third-party viewer. Empty
# when nettop cannot read it.
received_bytes() {
  # macOS has no timeout(1): perl alarm bounds a stalled nettop at 5 s, as gui-viewer.sh does.
  perl -e 'alarm 5; exec @ARGV' nettop -P -L 1 -n -x -J bytes_in -p "$1" 2>/dev/null \
    | awk -F, '$3 ~ /^[0-9]+$/ { last = $3 } END { if (last != "") print last }' || true
}

screen_sharing_app() {
  # EVAL_SCREEN_SHARING_APP: a test's stand-in (test_apple_bytes.py runs this target off a Mac).
  [[ -n "${EVAL_SCREEN_SHARING_APP:-}" ]] && echo "$EVAL_SCREEN_SHARING_APP" && return
  [[ -d "/System/Library/CoreServices/Applications/Screen Sharing.app" ]] && echo "/System/Library/CoreServices/Applications/Screen Sharing.app" && return
  [[ -d "/System/Library/CoreServices/Screen Sharing.app" ]] && echo "/System/Library/CoreServices/Screen Sharing.app" && return
  [[ -d "/System/Applications/Utilities/Screen Sharing.app" ]] && echo "/System/Applications/Utilities/Screen Sharing.app" && return
  return 1
}

# The Screen Sharing.app executable; every pid this target may quit runs exactly this path.
viewer_executable() {
  local app
  app=$(screen_sharing_app) || return 1
  echo "$app/Contents/MacOS/$(basename "$app" .app)"
}

# is_screen_sharing PID: PID is alive and runs the Screen Sharing executable (checked by path, so a
# reused pid that now belongs to another process never matches).
is_screen_sharing() {
  local cmd
  [[ "$1" =~ ^[1-9][0-9]*$ && -n "${apple_viewer_exe:-}" ]] || return 1
  cmd=$(ps -ww -p "$1" -o command= 2>/dev/null) || return 1
  cmd=${cmd#"${cmd%%[![:space:]]*}"}
  [[ "$cmd" == "$apple_viewer_exe" || "$cmd" == "$apple_viewer_exe "* ]]
}

# viewer_pids: every running Screen Sharing process, matched by executable path, one pid a line.
viewer_pids() {
  local pid cmd
  ps -ww -A -o pid= -o command= 2>/dev/null | while read -r pid cmd; do
    if [[ "$cmd" == "$apple_viewer_exe" || "$cmd" == "$apple_viewer_exe "* ]]; then
      echo "$pid"
    fi
  done
  return 0
}

# stop_viewer: quit the instance this run launched (EVAL_STATE/viewer.pid) and only it: TERM, up to
# 5 s, then KILL, each only while that pid still runs the Screen Sharing executable. Never by name.
stop_viewer() {
  local file="$EVAL_STATE/viewer.pid" pid
  pid=$(cat "$file" 2>/dev/null || true)
  if is_screen_sharing "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      is_screen_sharing "$pid" || break
      sleep 0.1 # bounded: 5 s for the viewer to quit
    done
    if is_screen_sharing "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$file"
}

# descendants PID: every process below PID (children, grandchildren, ...), one pid a line.
descendants() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2; order[NR] = $1 }
    END {
      want[root] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++) {
          p = order[i]
          if (!(p in want) && (parent[p] in want)) { want[p] = 1; grew = 1; print p }
        }
      } while (grew)
    }'
}

# start_watchdog LIMIT_S: bound this view verb. Past LIMIT_S a separate process quits the viewer
# this run launched, then this verb's own descendants and the verb itself (TERM, then KILL 5 s
# later), so a hung osascript or app cannot hold the run. It never touches its parent's process
# group: the caller (a test runner, peer.py) may share it.
# EVAL_APPLE_VIEW_DEADLINE_S is a test hook: it may only shorten the bound, never lengthen or disable it.
start_watchdog() {
  local limit=$1 override=${EVAL_APPLE_VIEW_DEADLINE_S:-}
  if [[ "$override" =~ ^[1-9][0-9]*$ ]] && (( override < limit )); then
    limit=$override
  fi
  rm -f "$EVAL_STATE/view-timed-out"
  bash -c "$(declare -f is_screen_sharing stop_viewer descendants)"'
    trap "kill \$nap 2>/dev/null; exit 0" TERM
    sleep "$1" </dev/null >/dev/null 2>&1 &
    nap=$!
    wait "$nap" 2>/dev/null || exit 0
    # The verb was killed outright (its EXIT trap never ran): pid $2 and viewer.pid may now
    # belong to something else, so act on nothing.
    [[ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d " ")" == "$2" ]] || exit 0
    echo "apple-$3: view passed its $1 s deadline; quit the viewer this run launched; next: check the viewer Mac for a hung Screen Sharing.app or osascript, then rerun" >&2
    : >"$EVAL_STATE/view-timed-out"
    stop_viewer
    for p in $(descendants "$2"); do
      [[ "$p" == "$$" ]] || kill -TERM "$p" 2>/dev/null || true
    done
    kill -TERM "$2" 2>/dev/null || exit 0
    for _ in $(seq 1 50); do
      kill -0 "$2" 2>/dev/null || exit 0
      sleep 0.1 # bounded: 5 s for the verb to exit on TERM
    done
    kill -KILL "$2" 2>/dev/null || true
  ' apple-watchdog "$limit" "$$" "$mode" &
  watchdog_pid=$!
}

# view_cleanup: the EXIT trap of every view verb, on success, failure or signal.
view_cleanup() {
  local status=$?
  # Finish cleanup even when the watchdog's TERM lands now. Cleanup is bounded on its own: its
  # only wait is stop_viewer's 5 s.
  trap - EXIT
  trap '' TERM INT HUP
  if [[ -n "${watchdog_pid:-}" ]]; then
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  stop_viewer || true
  if [[ -e "$EVAL_STATE/view-timed-out" ]]; then
    rm -f "$EVAL_STATE/view-timed-out"
    status=124
  fi
  exit "$status"
}

# begin_view LIMIT_S: arm the cleanup trap and the watchdog before anything is launched.
begin_view() {
  apple_viewer_exe=$(viewer_executable) || { echo "apple-$mode: Screen Sharing.app is unavailable" >&2; exit 1; }
  export apple_viewer_exe
  rm -f "$EVAL_STATE/viewer.pid"
  watchdog_pid=""
  trap view_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  start_watchdog "$1"
}

connect() {
  [[ "$host" != 127.* && "$host" != localhost ]] || {
    echo "apple-$mode: requires a second Mac; set lan=/viewer-of= or EVAL_APPLE_HOST" >&2
    return 1
  }
  app=$(screen_sharing_app) || return 1
  # A new instance (-n), never activated (-g): the run binds to and later quits only the pid it
  # launched, never a Screen Sharing window someone else opened.
  local before new count pid candidate expected
  before=" $(viewer_pids | tr '\n' ' ') "
  if ! open -g -n -a "$app" "vnc://$host" >/dev/null 2>&1; then
    echo "apple-$mode: Screen Sharing.app could not open the connection" >&2
    return 1
  fi
  new="" count=0
  for _ in $(seq 1 150); do
    new="" count=0
    for pid in $(viewer_pids); do
      case "$before" in *" $pid "*) ;; *) new=$pid; count=$((count + 1)) ;; esac
    done
    (( count >= 1 )) && break
    sleep 0.1 # bounded: the launched instance must appear within 15 s
  done
  # Hold for 1 s more: if a second Screen Sharing starts meanwhile, which one is ours is unknown,
  # so bind neither (a wrong bind would later quit someone else's viewer).
  if (( count == 1 )); then
    candidate=$new
    for _ in $(seq 1 10); do
      sleep 0.1 # bounded: 1 s settle
      new="" count=0
      for pid in $(viewer_pids); do
        case "$before" in *" $pid "*) ;; *) new=$pid; count=$((count + 1)) ;; esac
      done
      (( count == 1 )) && [[ "$new" == "$candidate" ]] || break
    done
  fi
  if (( count != 1 )); then
    echo "apple-$mode: found $count new Screen Sharing processes after open, not 1; next: rerun on a viewer Mac where nothing else launches Screen Sharing.app" >&2
    return 1
  fi
  echo "$new" >"$EVAL_STATE/viewer.pid"
  viewer_pid=$new
  if [[ -n "${EVAL_PRESENTED_OBSERVER_PID:-}" && "$EVAL_PRESENTED_OBSERVER_PID" != "$viewer_pid" ]]; then
    echo "apple-$mode: presented-pid=$EVAL_PRESENTED_OBSERVER_PID is not the instance this run launched ($viewer_pid); next: omit presented-pid= so the launched instance is used" >&2
    return 1
  fi
  expected=${EVAL_PRESENTED_OBSERVER_WINDOW:-}
  [[ -z "$expected" || "$expected" =~ ^[1-9][0-9]*$ ]] || {
    echo "apple-$mode: presented-window must be a numeric CGWindowID; next: pass one or omit it" >&2
    return 1
  }
  # Without presented-window, take the largest Screen Sharing window and accept it only when it
  # is the launched process's sole window.
  window_id=""
  for _ in $(seq 1 100); do
    candidate=$expected
    [[ -n "$candidate" ]] || candidate=$("$EVAL_BIN/screen-eval-window-id" "Screen Sharing" 2>/dev/null || true)
    if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
      window_id=$("$EVAL_BIN/screen-eval-window-id" "Screen Sharing" "$viewer_pid" "$candidate" 2>/dev/null || true)
      [[ "$window_id" == "$candidate" ]] && break
    fi
    window_id=""
    sleep 0.1
  done
  [[ -n "$window_id" ]] || {
    echo "apple-$mode: selected window is missing or ambiguous; next: leave one connection window in the selected process" >&2
    return 1
  }
  # These are the two quality settings of an Apple Standard connection,
  # not the separate High Performance connection type. Apple's documented
  # View menu contains the quality items directly (no Quality submenu).
  quality_item="Adaptive Quality"
  [[ "$mode" == high ]] && quality_item="Full Quality"
  # `set frontmost` and AXRaise take focus (the View menu acts only on the frontmost app). This
  # runs only on a dedicated fleet Mac: person_guard.py refuses apple* targets on a person's Mac.
  osascript - "$quality_item" "$viewer_pid" <<'OSA' || return 1
on run argv
  tell application "System Events"
    set selected_pid to (item 2 of argv) as integer
    tell (first application process whose unix id is selected_pid)
      repeat 50 times
        try
          if (count of windows) is not 1 then error "ambiguous Screen Sharing windows"
          set selected_window to window 1
          set frontmost to true
          perform action "AXRaise" of selected_window
          if (value of attribute "AXMain" of selected_window) is not true then error "selected window is not main"
          click menu bar item "View" of menu bar 1
          set item_name to item 1 of argv
          click menu item item_name of menu 1 of menu bar item "View" of menu bar 1
          delay 0.1
          click menu bar item "View" of menu bar 1
          set mark to value of attribute "AXMenuItemMarkChar" of menu item item_name of menu 1 of menu bar item "View" of menu bar 1
          if (mark is "✓" or mark is "checkmark") and (count of windows) is 1 and (value of attribute "AXMain" of selected_window) is true then
            key code 53
            return
          end if
        end try
        delay 0.1
      end repeat
    end tell
  end tell
  error "Screen Sharing quality menu is unavailable or the requested item is not selected"
end run
OSA
  # Recheck the native window identity after the app-wide menu action.
  [[ "$("$EVAL_BIN/screen-eval-window-id" "Screen Sharing" "$viewer_pid" "$window_id")" == "$window_id" ]] || return 1
  python3 -I - "$EVAL_STATE/apple-connection.json" "$host" "$mode" "$quality_item" "$window_id" "$viewer_pid" <<'PY'
import json, sys
json.dump({"host": sys.argv[2], "mode": sys.argv[3], "quality": sys.argv[4],
           "window": int(sys.argv[5]), "pid": int(sys.argv[6]),
           "quality_binding": "unique CG/AX window, raised and main before menu selection"}, open(sys.argv[1], "w"))
PY
}

# locate_marker: with no presented-marker-origin=/presented-cell-size=, the scene's counter row (the topmost
# 20-cell row) as Screen Sharing shows it on this display, in observe's capture pixels: marker-locate on a
# capture of the main display. The remote first frame can lag the connect, so it tries
# EVAL_APPLE_LOCATE_TRIES times (default 30), a second apart. Sets the caller's origin and cell.
locate_marker() {
  local tool="$EVAL_BIN/screen-eval-marker-locate" png="$EVAL_STATE/locate.png" err="$EVAL_STATE/locate.err"
  local tries=${EVAL_APPLE_LOCATE_TRIES:-30} found="" why="no display capture" i
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || tries=30
  [[ "${EVAL_PRESENTED_DISPLAY:-main}" == main ]] || {
    echo "apple-$mode: source readiness needs marker geometry for display ${EVAL_PRESENTED_DISPLAY}; next: pass presented-marker-origin= and presented-cell-size=" >&2
    return 1
  }
  [[ -x "$tool" ]] || {
    echo "apple-$mode: source readiness needs marker geometry: none given and no screen-eval-marker-locate in EVAL_BIN; next: build the target on the viewer, or pass presented-marker-origin= and presented-cell-size=" >&2
    return 1
  }
  for ((i = 1; i <= tries; i++)); do
    rm -f "$png"
    if screencapture -x -D 1 "$png" 2>/dev/null && [[ -s "$png" ]]; then
      if found=$("$tool" "$png" 2>"$err") && [[ "$found" =~ ^origin\ ([0-9]+),([0-9]+)\ cell\ ([0-9]+)\ at ]]; then
        origin="${BASH_REMATCH[1]},${BASH_REMATCH[2]}" cell=${BASH_REMATCH[3]}
        rm -f "$png" "$err"
        return 0
      fi
      why=$(tail -1 "$err" 2>/dev/null)
      [[ -n "$why" ]] || why="unreadable locate output: ${found:-none}"
    fi
    (( i < tries )) && sleep 1 # bounded: EVAL_APPLE_LOCATE_TRIES tries while the remote first frame arrives
  done
  rm -f "$png" "$err"
  echo "apple-$mode: source readiness needs marker geometry: marker-locate found no marker in $tries tries ($why); next: check the Screen Sharing window shows the host's scene, or pass presented-marker-origin= and presented-cell-size=" >&2
  return 1
}

verify_scene_ready() {
  local raw=$1 start="$EVAL_STATE/readiness-start"
  [[ "${EVAL_SCENE_NONCE:-}" =~ ^[0-9a-f]{32}$ ]] || {
    echo "apple-$mode: missing fresh source nonce; next: run the host half of screen-stream-eval.sh" >&2
    return 1
  }
  # connect() already bound viewer_pid (the launched instance) and window_id. presented-* geometry wins;
  # without it the marker is found on this display (locate_marker) and observed by the built cmux-rd.
  local observer=${EVAL_PRESENTED_OBSERVER_BIN:-$EVAL_BIN/cmux-rd}
  local origin=${EVAL_PRESENTED_MARKER_ORIGIN:-} cell=${EVAL_PRESENTED_CELL_SIZE:-} geometry=presented
  [[ -x "$observer" ]] || {
    echo "apple-$mode: observer unavailable at $observer; next: build the target on the viewer (targets/rd.sh build) or supply prebuilt cmux-rd with nonce observation support" >&2
    return 1
  }
  if [[ -z "$origin" || -z "$cell" ]]; then
    locate_marker || return 1
    geometry=marker-locate
  fi
  : >"$start" || return 1
  "$observer" observe --mode passive \
    --pid "$viewer_pid" --window "$window_id" --display "${EVAL_PRESENTED_DISPLAY:-main}" \
    --marker-origin "$origin" --cell-size "$cell" \
    --expected-nonce "$EVAL_SCENE_NONCE" --start-file "$start" --duration-s 1 --interval-ms 500 \
    >"$raw.readiness-observer.json" || {
      echo "apple-$mode: source readiness observer failed; next: verify the authorized remote scene and marker geometry" >&2
      return 1
    }
  python3 -I - "$raw.readiness-observer.json" "$raw.readiness.json" \
    "$EVAL_SCENE_NONCE" "$viewer_pid" "$window_id" "$host" "$mode" "$origin" "$cell" "$geometry" <<'PY' || return 1
import json, math, sys
receipt = json.load(open(sys.argv[1]))
changed = receipt.get("first_changed_marker_ms")
valid = (receipt.get("schema") == "cmux.presented-marker-series/2"
         and receipt.get("complete") is True
         and receipt.get("host_identity_verified") is True
         and receipt.get("nonce_observed") is True
         and receipt.get("expected_nonce") == sys.argv[3]
         and type(receipt.get("pid")) is int and receipt["pid"] == int(sys.argv[4])
         and type(receipt.get("window")) is int and receipt["window"] == int(sys.argv[5])
         and type(changed) in (int, float) and math.isfinite(changed) and changed >= 0)
if not valid:
    raise SystemExit("Apple source readiness was not proven; next: check the requested host, selected window, and fresh marker")
json.dump({"requested_host": sys.argv[6], "quality_profile": sys.argv[7],
           "expected_nonce": sys.argv[3], "observer": receipt,
           "marker_geometry": {"origin": sys.argv[8], "cell_size": int(sys.argv[9]), "source": sys.argv[10]}},
          open(sys.argv[2], "w"))
PY
}

case "$verb" in
  caps) echo viewer-grants ;;
  build)
    screen_sharing_app >/dev/null || { echo "apple-$mode: Screen Sharing.app is unavailable" >&2; exit 1; }
    command -v screencapture >/dev/null || { echo "apple-$mode: screencapture is unavailable" >&2; exit 1; }
    if [[ -n "${EVAL_PREBUILT:-}" ]]; then
      helper="$EVAL_PREBUILT/screen-eval-window-id"
      [[ -x "$helper" ]] || { echo "apple-$mode: prebuilt window-id helper missing or not executable: $helper" >&2; exit 1; }
      cp "$helper" "$EVAL_BIN/screen-eval-window-id" || {
        echo "apple-$mode: could not copy prebuilt window-id helper" >&2
        exit 1
      }
    else
      swiftc -O -o "$EVAL_BIN/screen-eval-window-id" "$EVAL_ROOT/scripts/measure/screen-stream-eval/window-id.swift"
    fi
    # The viewer Mac (viewer-of=, or presented-observer=1) proves source readiness with cmux-rd observe,
    # and without presented-* geometry finds the marker with marker-locate; apple-only viewer steps
    # otherwise never build either. Another target's build may already have put cmux-rd there.
    if [[ -n "${EVAL_PRESENTED_OBSERVER_BIN:-}" || -n "${EVAL_VIEWER_OF:-}" ]]; then
      if [[ -n "${EVAL_PREBUILT:-}" ]]; then
        [[ -x "$EVAL_PREBUILT/cmux-rd" ]] || { echo "apple-$mode: prebuilt cmux-rd observer missing or not executable" >&2; exit 1; }
        cp "$EVAL_PREBUILT/cmux-rd" "$EVAL_BIN/cmux-rd"
        [[ ! -x "$EVAL_PREBUILT/screen-eval-marker-locate" ]] || cp "$EVAL_PREBUILT/screen-eval-marker-locate" "$EVAL_BIN/"
      else
        [[ -x "$EVAL_BIN/cmux-rd" ]] || bash "$EVAL_ROOT/scripts/measure/screen-stream-eval/targets/rd.sh" build || exit 1
        [[ -x "$EVAL_BIN/screen-eval-marker-locate" ]] ||
          swiftc -O -o "$EVAL_BIN/screen-eval-marker-locate" "$EVAL_ROOT/scripts/measure/screen-stream-eval/marker-locate.swift" || exit 1
      fi
    fi
    ;;
  host-start)
    # Screen Sharing's system service is already enabled on the dedicated measure
    # Macs. The target never changes that service or its authorization state.
    screen_sharing_app >/dev/null || exit 1
    ;;
  host-stop) ;;
  latency-view)
    input=$1; raw=$3
    samples=$2
    [[ "$samples" =~ ^[0-9]+$ ]] || { echo "apple-$mode: latency samples must be a whole number" >&2; exit 2; }
    begin_view $((samples * 2 + 120))
    if [[ -n "${EVAL_PRESENTED_OBSERVER_BIN:-}" ]]; then
      # The managed GUI step may opt into cmux-rd's protocol-independent
      # compositor observer. Every identity and geometry value is explicit so
      # this target cannot silently observe another Screen Sharing window.
      for var in EVAL_PRESENTED_MARKER_ORIGIN EVAL_PRESENTED_CELL_SIZE EVAL_PRESENTED_INPUT_POINT; do
        [[ -n "${!var:-}" ]] || {
          echo "apple-$mode: presented observer requires $var" >&2
          exit 1
        }
      done
      [[ -x "$EVAL_PRESENTED_OBSERVER_BIN" ]] || {
        echo "apple-$mode: presented observer is not executable: $EVAL_PRESENTED_OBSERVER_BIN" >&2
        exit 1
      }
      connect || exit 1
      kind=key
      [[ "$input" == pointer ]] && kind=click
      observer_raw="$raw.observer"
      if ! "$EVAL_PRESENTED_OBSERVER_BIN" observe \
        --pid "$viewer_pid" \
        --window "$window_id" \
        --display "${EVAL_PRESENTED_DISPLAY:-main}" \
        --marker-origin "$EVAL_PRESENTED_MARKER_ORIGIN" \
        --cell-size "$EVAL_PRESENTED_CELL_SIZE" \
        --at "$EVAL_PRESENTED_INPUT_POINT" \
        --input "$kind" --samples "$2" \
        --timeout-ms "${EVAL_PRESENTED_TIMEOUT_MS:-1000}" \
        --seed "${EVAL_PRESENTED_SEED:-1}" >"$observer_raw"; then
        echo "apple-$mode: presented observer did not produce a complete marker receipt" >"$EVAL_STATE/latency.err"
        exit 1
      fi
      python3 -I - "$observer_raw" "$raw" "$mode" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
if receipt.get("schema") != "cmux.presented-marker/1" or not receipt.get("complete"):
    raise SystemExit("incomplete presented-marker receipt")
json.dump({
    "g2g_ms": {"n": receipt["n"], "p50": receipt["p50_ms"], "p95": receipt["p95_ms"]},
    "lost": 0,
    "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None,
               "decode_ms": None, "method": receipt.get("method", "cmux-rd presented observer")},
    "mode": sys.argv[3], "observer": receipt,
}, open(sys.argv[2], "w"))
PY
      exit 0
    fi
    # Without the explicit observer contract Apple has no supported
    # input/frame timestamp API. Keep this row unavailable rather than mixing
    # decode, screenshot or stale-window timing into the comparison.
    printf '{"g2g_ms":{},"lost":null,"split":{"method":"apple-screen-sharing-app: no supported glass-to-glass timestamp API"},"mode":"%s","input":"%s"}\n' "$mode" "$input" >"$raw"
    echo "apple-$mode: Apple Screen Sharing.app exposes no supported per-input frame timestamp; latency row is unavailable" >"$EVAL_STATE/latency.err"
    ;;
  latency-report)
    input=$1; raw=$2; out=$3
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
json.dump({"g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
           "observer": raw.get("observer"),
           "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None,
                     "decode_ms": None, "method": raw.get("split", {}).get("method")}}, open(sys.argv[2], "w"))
PY
    ;;
  window-view)
    seconds=$1; snapshot=$2; go=$3; raw=$4
    [[ "$seconds" =~ ^[0-9]+$ ]] || { echo "apple-$mode: window seconds must be a whole number" >&2; exit 2; }
    # A previous repeat's GO and receipts go first, so no refusal below (begin_view's included) leaves them.
    rm -f "$go" "$raw.readiness.json" "$raw.readiness-observer.json"
    begin_view $((seconds + 120))
    connect || exit 1
    verify_scene_ready "$raw" || exit 1
    # Only a fresh nonce from the requested source in this exact selected
    # window may start the workload. A screenshot alone proves neither.
    touch "$go"
    # Capture only the remote Screen Sharing window. A full-display capture
    # would measure the local scene and is not evidence about Apple's stream.
    deadline=$((SECONDS + seconds))
    # Screen Sharing exposes neither a decoded-frame readiness marker nor a
    # supported presentation timestamp. Keep first-frame unavailable rather
    # than treating a screenshot of a stale/connecting window as remote data.
    first_ms=""
    seen_frame=0
    last_hash=""
    # kbps: Screen Sharing.app's received bytes (VNC payload plus headers), read at each
    # bucket's end, so a bucket's bytes and duration span the same two reads.
    bytes_last=$(received_bytes "$viewer_pid")
    bytes_total=0
    bytes_ok=1
    [[ -n "$bytes_last" ]] || bytes_ok=0
    bucket_start_ms=$(now_ms)
    bucket_frames=0
    rows=()
    row_bytes=()
    cpu_sum=0
    cpu_count=0
    # close_bucket: one row for the bucket that ends now. Each count belongs to its actual
    # elapsed duration; the bytes are those received between this read and the last.
    close_bucket() {
      local total delta=null
      total=$(received_bytes "$viewer_pid")
      now=$(now_ms)
      if [[ -n "$total" && -n "$bytes_last" ]] && (( total >= bytes_last )); then
        delta=$((total - bytes_last))
        bytes_total=$((bytes_total + delta))
      else
        bytes_ok=0
      fi
      bytes_last=$total
      rows+=("{\"unix_ms\":$now,\"duration_ms\":$((now - bucket_start_ms)),\"bytes\":@BYTES@,\"frames\":null,\"sampled_changes\":$bucket_frames}")
      row_bytes+=("$delta")
      bucket_start_ms=$now
      bucket_frames=0
    }
    i=0
    while (( SECONDS < deadline )); do
      png="$EVAL_STATE/frame-$i.png"
      if screencapture -x -o -l "$window_id" "$png" 2>/dev/null && [[ -s "$png" ]]; then
        now=$(now_ms)
        cpu_sample=$(ps -p "$viewer_pid" -o %cpu= 2>/dev/null | awk '{print $1 + 0}')
        if [[ -n "$cpu_sample" ]]; then
          cpu_sum=$(awk -v sum="$cpu_sum" -v value="$cpu_sample" 'BEGIN { print sum + value }')
          cpu_count=$((cpu_count + 1))
        fi
        hash=$(shasum -a 256 "$png" | awk '{print $1}')
        changed=0
        [[ "$seen_frame" == 1 && "$hash" != "$last_hash" ]] && changed=1
        seen_frame=1
        # The PNG screenshot is a local observation: it counts sampled changes, never bytes.
        bucket_frames=$((bucket_frames + changed))
        if (( now - bucket_start_ms >= 1000 )); then
          close_bucket
        fi
        last_hash=$hash
        cp "$png" "$snapshot"
      fi
      i=$((i + 1))
      sleep 0.1
    done
    if (( bucket_frames > 0 )); then
      close_bucket
    fi
    # A failed read, or no bytes at all while the window ran (the stream lives in another
    # process), is not a measured zero: every row's bytes stay null and the run says why.
    bytes_method="nettop bytes_in of the Screen Sharing.app viewer process, all sockets"
    bytes_unavailable=false
    if (( bytes_ok == 0 || bytes_total == 0 )); then
      bytes_method="nettop read no received bytes for the Screen Sharing.app viewer process"
      bytes_unavailable=true
    fi
    for idx in "${!rows[@]}"; do
      value=${row_bytes[$idx]}
      [[ "$bytes_unavailable" == true ]] && value=null
      rows[$idx]=${rows[$idx]/@BYTES@/$value}
    done
    cpu=null
    if (( cpu_count > 0 )); then
      cpu=$(awk -v sum="$cpu_sum" -v count="$cpu_count" 'BEGIN { printf "%.3f", sum / count }')
    fi
    printf '{"series":[%s],"extra":{"first_frame_ms":%s,"cpu_pct":%s,"mode":"%s","viewer":"Screen Sharing.app","bytes_method":"%s","bytes_unavailable":%s,"readiness":%s}}\n' \
      "$(IFS=,; echo "${rows[*]-}")" "${first_ms:-null}" "${cpu:-null}" "$mode" "$bytes_method" "$bytes_unavailable" \
      "$(cat "$raw.readiness.json")" >"$raw"
    ;;
  window-report)
    raw=$1; out=$2
    python3 -I - "$raw" "$out" "${EVAL_PEER_WALL_OFFSET_MS:-0}" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
offset = float(sys.argv[3])
series = [{**row, "unix_ms": round(row["unix_ms"] + offset)} for row in (raw.get("series") or [])]
extra = raw.get("extra") or {}
json.dump({"series": series, "extra": {"first_frame_ms": extra.get("first_frame_ms"),
                                         "cpu_pct": extra.get("cpu_pct"),
                                         "readiness": extra.get("readiness"),
                                         "mode": extra.get("mode"), "viewer": extra.get("viewer"),
                                         "bytes_method": extra.get("bytes_method"),
                                         "bytes_unavailable": extra.get("bytes_unavailable") is True}},
          open(sys.argv[2], "w"))
PY
    ;;
  *) echo "apple.sh: unknown verb $verb" >&2; exit 2 ;;
esac
