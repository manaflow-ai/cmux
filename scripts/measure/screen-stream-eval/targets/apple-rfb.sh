#!/usr/bin/env bash
# Apple's Screen Sharing server measured headless: rfb-viewer.py logs in to the host Mac's
# screensharingd (the macOS account login, RFB type 30) from a shell on the viewer Mac and times
# its frame updates against the marker. No window opens on either Mac, nothing takes focus, and
# nothing is left running: each view is one bounded process. README.md, "apple-rfb".
set -euo pipefail
verb=$1
shift
host=${EVAL_PEER:-${EVAL_APPLE_HOST:-}}
viewer="$EVAL_ROOT/scripts/measure/screen-stream-eval/rfb-viewer.py"

need_host() {
  [[ -n "$host" && "$host" != 127.* && "$host" != localhost ]] || {
    echo "apple-rfb: needs a second Mac (viewer-of= on the viewer, lan= on the host); Screen Sharing serves no loopback viewer" >&2
    exit 1
  }
}

case "$verb" in
  caps) ;;  # a protocol client like rd's bench: no grants on the viewer Mac
  build) [[ -f "$viewer" ]] ;;
  host-start)
    # Screen Sharing is a system service on the dedicated host Mac; the target never turns it on.
    nc -z -G 3 "${EVAL_BIND:-127.0.0.1}" 5900 2>/dev/null || {
      echo "apple-rfb: nothing listens on port 5900 here; Screen Sharing is off on this Mac" >&2
      exit 1
    }
    ;;
  host-stop) ;;
  latency-view)
    need_host
    input=$1 samples=$2 raw=$3
    # A hard bound per view, so a stalled server can never hold the run.
    perl -e 'alarm shift; exec @ARGV' $((samples * 2 + 120)) \
      python3 -I "$viewer" latency --host "$host" --input "$input" --samples "$samples" \
      --marker-log "${EVAL_MARKER_LOG:-}" --out "$raw" 2>"$EVAL_STATE/latency-$input.err"
    ;;
  latency-report)
    raw=$2 out=$3
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
json.dump({"g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"), "split": raw.get("split") or {},
           "geometry": raw.get("geometry"), "encodings_seen": raw.get("encodings_seen")}, open(sys.argv[2], "w"))
PY
    ;;
  window-view)
    need_host
    seconds=$1 snapshot=$2 go=$3 raw=$4
    nonce=()
    [[ -n "${EVAL_SCENE_NONCE:-}" ]] && nonce=(--nonce "$EVAL_SCENE_NONCE")
    rc=0
    perl -e 'alarm shift; exec @ARGV' $((seconds + 120)) \
      python3 -I "$viewer" window --host "$host" --seconds "$seconds" --frame "$snapshot" --go "$go" \
      --out "$raw" ${nonce[@]+"${nonce[@]}"} 2>"$EVAL_STATE/window.err" || rc=$?
    # The scene waits for GO: a viewer that failed before it must still release the host's timeline.
    [[ -e "$go" ]] || touch "$go"
    [[ "$rc" == 0 ]] || { cat "$EVAL_STATE/window.err" >&2; exit "$rc"; }
    ;;
  window-report)
    raw=$1 out=$2
    python3 -I - "$raw" "$out" "${EVAL_PEER_WALL_OFFSET_MS:-0}" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
offset = float(sys.argv[3])
series = [{**row, "unix_ms": round(row["unix_ms"] + offset)} for row in raw.get("series") or []]
json.dump({"series": series, "extra": raw.get("extra") or {}}, open(sys.argv[2], "w"))
PY
    ;;
  *) echo "apple-rfb.sh: unknown verb $verb" >&2; exit 2 ;;
esac
