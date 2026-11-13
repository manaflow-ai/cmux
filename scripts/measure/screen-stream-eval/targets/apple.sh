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

screen_sharing_app() {
  [[ -d "/System/Library/CoreServices/Screen Sharing.app" ]] && echo "/System/Library/CoreServices/Screen Sharing.app" && return
  [[ -d "/System/Applications/Utilities/Screen Sharing.app" ]] && echo "/System/Applications/Utilities/Screen Sharing.app" && return
  return 1
}

connect() {
  [[ "$host" != 127.* && "$host" != localhost ]] || {
    echo "apple-$mode: requires a second Mac; set lan=/viewer-of= or EVAL_APPLE_HOST" >&2
    return 1
  }
  app=$(screen_sharing_app) || return 1
  if ! open -g -a "$app" "vnc://$host" >/dev/null 2>&1; then
    echo "apple-$mode: Screen Sharing.app could not open the connection" >&2
    return 1
  fi
  # These are the two quality settings of an Apple Standard connection,
  # not the separate High Performance connection type. Apple's documented
  # View menu contains the quality items directly (no Quality submenu).
  quality_item="Adaptive Quality"
  [[ "$mode" == high ]] && quality_item="Full Quality"
  osascript - "$quality_item" <<'OSA' || return 1
on run argv
  tell application "System Events"
    tell process "Screen Sharing"
      repeat 50 times
        try
          click menu bar item "View" of menu bar 1
          set item_name to item 1 of argv
          click menu item item_name of menu 1 of menu bar item "View" of menu bar 1
          delay 0.1
          click menu bar item "View" of menu bar 1
          set mark to value of attribute "AXMenuItemMarkChar" of menu item item_name of menu 1 of menu bar item "View" of menu bar 1
          if mark is "✓" or mark is "checkmark" then
            key code 53
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "Screen Sharing quality menu is unavailable or the requested item is not selected"
end run
OSA
  window_id=""
  for _ in $(seq 1 100); do
    window_id=$("$EVAL_BIN/screen-eval-window-id" "Screen Sharing" 2>/dev/null || true)
    [[ "$window_id" =~ ^[0-9]+$ ]] && break
    sleep 0.1
  done
  [[ "$window_id" =~ ^[0-9]+$ ]] || { echo "apple-$mode: Screen Sharing window id unavailable" >&2; return 1; }
  viewer_pid=$(ps -axo pid=,comm= | awk '$0 ~ /Screen Sharing/ {print $1; exit}')
  [[ "$viewer_pid" =~ ^[0-9]+$ ]] || { echo "apple-$mode: Screen Sharing process unavailable" >&2; return 1; }
  if [[ -n "${EVAL_PRESENTED_OBSERVER_WINDOW:-}" && "$window_id" != "$EVAL_PRESENTED_OBSERVER_WINDOW" ]]; then
    echo "apple-$mode: selected Screen Sharing window id $window_id differs from presented-window=$EVAL_PRESENTED_OBSERVER_WINDOW" >&2
    return 1
  fi
  if [[ -n "${EVAL_PRESENTED_OBSERVER_PID:-}" && "$viewer_pid" != "$EVAL_PRESENTED_OBSERVER_PID" ]]; then
    echo "apple-$mode: selected Screen Sharing pid $viewer_pid differs from presented-pid=$EVAL_PRESENTED_OBSERVER_PID" >&2
    return 1
  fi
  python3 -I - "$EVAL_STATE/apple-connection.json" "$host" "$mode" "$quality_item" "$window_id" "$viewer_pid" <<'PY'
import json, sys
json.dump({"host": sys.argv[2], "mode": sys.argv[3], "quality": sys.argv[4],
           "window": int(sys.argv[5]), "pid": int(sys.argv[6])}, open(sys.argv[1], "w"))
PY
}

case "$verb" in
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
    if [[ -n "${EVAL_PRESENTED_OBSERVER_BIN:-}" ]]; then
      # Apple-only viewer steps otherwise never build/copy the rd executable.
      if [[ -n "${EVAL_PREBUILT:-}" ]]; then
        [[ -x "$EVAL_PREBUILT/cmux-rd" ]] || { echo "apple-$mode: prebuilt cmux-rd observer missing or not executable" >&2; exit 1; }
        cp "$EVAL_PREBUILT/cmux-rd" "$EVAL_BIN/cmux-rd"
      else
        bash "$EVAL_ROOT/scripts/measure/screen-stream-eval/targets/rd.sh" build
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
    if [[ -n "${EVAL_PRESENTED_OBSERVER_BIN:-}" ]]; then
      # The managed GUI step may opt into cmux-rd's protocol-independent
      # compositor observer. Every identity and geometry value is explicit so
      # this target cannot silently observe another Screen Sharing window.
      for var in EVAL_PRESENTED_OBSERVER_PID EVAL_PRESENTED_OBSERVER_WINDOW \
        EVAL_PRESENTED_MARKER_ORIGIN EVAL_PRESENTED_CELL_SIZE EVAL_PRESENTED_INPUT_POINT; do
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
        --pid "$EVAL_PRESENTED_OBSERVER_PID" \
        --window "$EVAL_PRESENTED_OBSERVER_WINDOW" \
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
    connect || exit 1
    # Capture only the remote Screen Sharing window. A full-display capture
    # would measure the local scene and is not evidence about Apple's stream.
    deadline=$((SECONDS + seconds))
    # Screen Sharing exposes neither a decoded-frame readiness marker nor a
    # supported presentation timestamp. Keep first-frame unavailable rather
    # than treating a screenshot of a stale/connecting window as remote data.
    first_ms=""
    seen_frame=0
    last_hash=""
    bucket_start_ms=""
    bucket_frames=0
    rows=()
    cpu_sum=0
    cpu_count=0
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
        if [[ "$seen_frame" == 0 ]]; then
          touch "$go"
          seen_frame=1
        fi
        if [[ -z "$bucket_start_ms" ]]; then bucket_start_ms=$now; fi
        # Screen Sharing.app's PNG screenshot is a local observation, not the
        # VNC transport payload. Keep kbps explicitly unavailable.
        bucket_frames=$((bucket_frames + changed))
        if (( now - bucket_start_ms >= 1000 )); then
          # Each count belongs to this bucket's actual elapsed duration.
          rows+=("{\"unix_ms\":$now,\"duration_ms\":$((now - bucket_start_ms)),\"bytes\":null,\"frames\":null,\"sampled_changes\":$bucket_frames}")
          bucket_start_ms=$now
          bucket_frames=0
        fi
        last_hash=$hash
        cp "$png" "$snapshot"
      fi
      i=$((i + 1))
      sleep 0.1
    done
    if (( bucket_frames > 0 )); then
      rows+=("{\"unix_ms\":$now,\"duration_ms\":$((now - bucket_start_ms)),\"bytes\":null,\"frames\":null,\"sampled_changes\":$bucket_frames}")
    fi
    [[ -e "$go" ]] || touch "$go"
    cpu=null
    if (( cpu_count > 0 )); then
      cpu=$(awk -v sum="$cpu_sum" -v count="$cpu_count" 'BEGIN { printf "%.3f", sum / count }')
    fi
    printf '{"series":[%s],"extra":{"first_frame_ms":%s,"cpu_pct":%s,"mode":"%s","viewer":"Screen Sharing.app","bytes_method":"Screen Sharing.app transport bytes are not exposed"}}\n' \
      "$(IFS=,; echo "${rows[*]-}")" "${first_ms:-null}" "${cpu:-null}" "$mode" >"$raw"
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
                                         "mode": extra.get("mode"), "viewer": extra.get("viewer")}}, open(sys.argv[2], "w"))
PY
    ;;
  *) echo "apple.sh: unknown verb $verb" >&2; exit 2 ;;
esac
