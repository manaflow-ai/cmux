#!/usr/bin/env bash
# Screen stream eval target: rd's stream as a person sees it on the viewer Mac. The same host as
# `rd` (rd.sh: `cmux-rd host`, the same token), and as the viewer `cmux-rd bench --present window`,
# which decodes with VideoToolbox like `rd` and also shows every frame in an on-screen window and
# sends the keys typed into it to the host. `cmux-rd observe` then times each key, posted to that
# window's process, to the ScreenCaptureKit frame of the viewer's display in which the host's
# marker counter changed: key to presented frame, the number Apple's targets get the same way.
#
# Not the cmux app's Mac Screen pane: a Rust window that presents the decoded IOSurface as a
# layer's contents (the pane's layer presenter; its default draws the same surface with Metal).
# The pane itself needs a signed-in app build, which a fleet step cannot open (README.md).
#
# The marker geometry is never given: observe finds the marker in the bench's window
# (`--marker-origin auto`) and refuses to time anything when it is not there.
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rd="${EVAL_BIN:-}/cmux-rd"
port=4103

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

# stop_bench: end the bench this view started (its pid and start time recorded), and only it.
stop_bench() {
  local file="$EVAL_STATE/present.pid" pid start
  [[ -f "$file" ]] || return 0
  pid=$(cat "$file")
  start=$(cat "$file.start" 2>/dev/null || true)
  if [[ "$pid" =~ ^[0-9]+$ && -n "$start" && "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" == "$start" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1 # bounded: 5 s for the bench to exit
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$file" "$file.start"
  return 0
}

case "$verb" in
  build)
    bash "$here/rd.sh" build
    ;;
  host-start | host-stop) bash "$here/rd.sh" "$verb" ;;
  # observe posts input and captures the display on the viewer Mac: that half needs the grants.
  caps) echo viewer-grants ;;
  latency-view)
    input=$1 samples=$2 raw=$3
    [[ "$samples" =~ ^[1-9][0-9]*$ ]] || { echo "rd-present: latency samples must be a whole number" >&2; exit 2; }
    if [[ "$input" != key ]]; then
      # The window forwards keys only; a click would time nothing the viewer sends.
      printf '{"g2g_ms":{},"lost":null,"split":{"method":"rd-present: pointer input is not forwarded by the presenting window"}}\n' >"$raw"
      exit 0
    fi
    trap stop_bench EXIT
    out="$EVAL_STATE/present.out" err="$EVAL_STATE/present.err"
    rm -f "$out" "$err"
    flags=()
    [[ -z "${EVAL_PEER:-}" || "${EVAL_PEER}" == 127.0.0.1 ]] && flags+=(--eval-local 1)
    # Long enough for every sample at the observer's 75 ms jitter plus a full timeout each.
    duration=$((samples * (75 + ${EVAL_PRESENTED_TIMEOUT_MS:-1000}) / 1000 + 60))
    "$rd" bench ${flags[@]+"${flags[@]}"} --addr "${EVAL_PEER:-127.0.0.1}:$port" --user owner --token-fd 3 \
      --input none --duration-s "$duration" --present window --present-title "cmux rd present" \
      3< <(cat "$EVAL_STATE/token") >"$out" 2>"$err" &
    pid=$!
    echo "$pid" >"$EVAL_STATE/present.pid"
    LC_ALL=C ps -p "$pid" -o lstart= >"$EVAL_STATE/present.pid.start" || true
    window="" first=""
    for _ in $(seq 1 200); do
      [[ -z "$window" ]] && window=$(python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and "present_window" in m:
        if m.get("pid") != int(sys.argv[2]):
            sys.exit("pid mismatch")
        print(m["present_window"]); break
' "$out" "$pid" 2>/dev/null || true)
      grep -q 'passive: first frame' "$err" 2>/dev/null && first=1
      [[ -n "$window" && -n "$first" ]] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1 # bounded: 20 s for the window and the first frame
    done
    if [[ -z "$window" || -z "$first" ]]; then
      echo "rd-present: the presenting bench showed no window or no first frame within 20 s; next: check $err" >&2
      tail -20 "$err" >&2 || true
      exit 1
    fi
    if ! "$rd" observe --pid "$pid" --window "$window" --display "${EVAL_PRESENTED_DISPLAY:-main}" \
      --marker-origin auto --input key --samples "$samples" \
      --timeout-ms "${EVAL_PRESENTED_TIMEOUT_MS:-1000}" --seed "${EVAL_PRESENTED_SEED:-1}" \
      >"$raw.observer" 2>"$raw.observer.err"; then
      echo "rd-present: observe did not complete: $(tail -1 "$raw.observer.err")" >&2
      cat "$raw.observer.err" >&2
      exit 1
    fi
    cp "$raw.observer" "$raw"
    ;;
  latency-report)
    input=$1 raw=$2 out=$3
    python3 -I - "$raw" "$out" <<'PY'
import json, sys
text = open(sys.argv[1]).read().strip()
raw = json.loads(text) if text else {}
ok = raw.get("schema") == "cmux.presented-marker/1" and raw.get("complete") is True
g2g = {"n": raw["n"], "p50": raw["p50_ms"], "p95": raw["p95_ms"]} if ok else {}
method = ("rd-present: CGEventPostToPid key to the bench window, to the ScreenCaptureKit display time of "
          "the viewer frame whose marker changed (key to presented frame); marker calibrated in that window")
json.dump({"g2g_ms": g2g, "lost": 0 if ok else None,
           "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None, "decode_ms": None,
                     "method": method if ok else (raw.get("split") or {}).get("method", "rd-present: no receipt")},
           "observer": {k: v for k, v in raw.items() if k != "samples_us"} if ok else None,
           "samples_us": raw.get("samples_us") if ok else None}, open(sys.argv[2], "w"))
PY
    ;;
  window-view)
    # The same passive window as rd, its frames also presented on screen.
    EVAL_RD_BENCH_PRESENT=1 bash "$here/rd.sh" window-view "$@"
    ;;
  window-report) bash "$here/rd.sh" window-report "$@" ;;
  *) echo "rd-present.sh: unknown verb $verb" >&2; exit 2 ;;
esac
