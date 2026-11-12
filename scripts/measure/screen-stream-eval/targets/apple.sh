#!/usr/bin/env bash
# Apple Screen Sharing.app target. The wrapper targets apple-high and
# apple-standard set EVAL_APPLE_MODE before invoking this file.
set -euo pipefail
verb=$1
shift
mode=${EVAL_APPLE_MODE:-high}
host=${EVAL_PEER:-${EVAL_APPLE_HOST:-127.0.0.1}}

screen_sharing_app() {
  [[ -d "/System/Library/CoreServices/Screen Sharing.app" ]] && echo "/System/Library/CoreServices/Screen Sharing.app" && return
  [[ -d "/System/Applications/Utilities/Screen Sharing.app" ]] && echo "/System/Applications/Utilities/Screen Sharing.app" && return
  return 1
}

case "$verb" in
  build)
    screen_sharing_app >/dev/null || { echo "apple-$mode: Screen Sharing.app is unavailable" >&2; exit 1; }
    command -v screencapture >/dev/null || { echo "apple-$mode: screencapture is unavailable" >&2; exit 1; }
    ;;
  host-start)
    # Screen Sharing's system service is already enabled on the dedicated measure
    # Macs. The target never changes that service or its authorization state.
    screen_sharing_app >/dev/null || exit 1
    ;;
  host-stop) ;;
  latency-view)
    # Apple does not expose a supported input/frame timestamp API. Keep this row
    # explicit rather than mixing a different protocol into the comparison.
    input=$1; raw=$3
    printf '{"g2g_ms":{},"lost":null,"split":{"method":"apple-screen-sharing-app: no supported glass-to-glass timestamp API"},"mode":"%s","input":"%s"}\n' "$mode" "$input" >"$raw"
    echo "apple-$mode: Apple Screen Sharing.app exposes no supported per-input frame timestamp; latency row is unavailable" >"$EVAL_STATE/latency.err"
    ;;
  latency-report)
    input=$1; raw=$2; out=$3
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
json.dump({"g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
           "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None,
                     "decode_ms": None, "method": raw.get("split", {}).get("method")}}, open(sys.argv[2], "w"))
PY
    ;;
  window-view)
    seconds=$1; snapshot=$2; go=$3; raw=$4
    app=$(screen_sharing_app)
    open -g -a "$app" "vnc://$host" >/dev/null 2>&1 || true
    # Wait for the app's window to become capturable, then sample the front-most
    # display. Screen Sharing.app is deliberately the only viewer in this target.
    start_ms=$(date +%s%3N)
    deadline=$((SECONDS + seconds))
    first_ms=""
    last_hash=""
    rows=()
    i=0
    while (( SECONDS < deadline )); do
      png="$EVAL_STATE/frame-$i.png"
      if screencapture -x -o "$png" 2>/dev/null && [[ -s "$png" ]]; then
        now=$(date +%s%3N)
        hash=$(shasum -a 256 "$png" | awk '{print $1}')
        changed=0
        [[ -n "$first_ms" && "$hash" != "$last_hash" ]] && changed=1
        if [[ -z "$first_ms" ]]; then
          first_ms=$((now - start_ms))
          echo "$first_ms" >"$raw.first"
          touch "$go"
        fi
        bytes=$(stat -f %z "$png" 2>/dev/null || wc -c <"$png")
        rows+=("{\"unix_ms\":$now,\"bytes\":$bytes,\"frames\":$changed}")
        last_hash=$hash
        cp "$png" "$snapshot"
      fi
      i=$((i + 1))
      sleep 1
    done
    [[ -e "$go" ]] || touch "$go"
    cpu=$(ps -axo comm=,%cpu= | awk '$1 ~ /Screen/ {sum += $2} END {print sum + 0}')
    printf '{"series":[%s],"extra":{"first_frame_ms":%s,"cpu_pct":%s,"mode":"%s","viewer":"Screen Sharing.app"}}\n' \
      "$(IFS=,; echo "${rows[*]-}")" "${first_ms:-null}" "${cpu:-null}" "$mode" >"$raw"
    ;;
  window-report)
    raw=$1; out=$2
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
series = raw.get("series") or []
extra = raw.get("extra") or {}
json.dump({"series": series, "extra": {"first_frame_ms": extra.get("first_frame_ms"),
                                         "cpu_pct": extra.get("cpu_pct"),
                                         "mode": extra.get("mode"), "viewer": extra.get("viewer")}}, open(sys.argv[2], "w"))
PY
    ;;
  *) echo "apple.sh: unknown verb $verb" >&2; exit 2 ;;
esac
