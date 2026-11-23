#!/usr/bin/env bash
# The resolution ladder on a fleet Mac's VideoToolbox (screen share P4, D3/D5): one synthetic
# `cmux-rd host` and one passive `cmux-rd bench` over loopback per row, then one line each:
# frames, encoder drops, the picture most frames had, mean bits per pixel, and the host's error.
# Fails when a ladder session with a `video.scaled` viewer streams no frames or ends on an
# encode error (the VideoToolbox -12902 of a QP floor over the ladder's ceiling, cmux#51389).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/rd-ladder-check.sh \
#     --ref SHA --target-worker cmuxNN --pin-strict --artifact artifacts/rd-ladder-check/out.txt
# Options (KEY=VALUE args): seconds= per row (8), kbps= the rate pin (400 1000 2000), scenes= (text churn).
set -u
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 2
seconds=8 kbps="400 1000 2000" scenes="text churn"
for arg in "$@"; do
  case "$arg" in
    seconds=*) seconds="${arg#seconds=}" ;;
    kbps=*) kbps="${arg#kbps=}" ;;
    scenes=*) scenes="${arg#scenes=}" ;;
    *) echo "rd-ladder-check.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo "rd-ladder-check.sh: VideoToolbox needs a Mac" >&2; exit 2; }
out="$root/artifacts/rd-ladder-check"
work="$root/.build/rd-ladder-check"
rm -rf "$out" "$work"
mkdir -p "$out" "$work/bin"
exec > >(tee "$out/out.txt") 2>&1
export EVAL_ROOT="$root" EVAL_BIN="$work/bin"
bash scripts/measure/screen-stream-eval/targets/rd.sh build || { echo "FAIL build"; exit 4; }
B="$work/bin/cmux-rd"
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
port=4119
host_pid=""
stop() { [[ -n "$host_pid" ]] && { kill "$host_pid" 2>/dev/null; wait "$host_pid" 2>/dev/null; }; host_pid=""; }
trap stop EXIT
fails=0
echo "rd-ladder-check $(git rev-parse --short=12 HEAD) on $(hostname -s), ${seconds}s per row"
printf '%-34s %6s %5s %-10s %6s %s\n' row frames drops picture bpp error
for scene in $scenes; do
  for rate in $kbps; do
    for mode in base ladder; do
      for caps in none video.scaled; do
        tag="$scene-$rate-$mode-$caps"
        args=(--owner owner --port "$port" --source synthetic --synthetic-scene "$scene" --profile high
          --idle-exit-s 20 --max-kbps "$rate")
        [[ "$mode" == ladder ]] && args+=(--resolution-ladder 1 --max-qp 40)
        viewer=()
        [[ "$caps" != none ]] && viewer=(--caps "$caps")
        CMUX_RD_TIMING_LOG="$work/timing-$tag.jsonl" "$B" host "${args[@]}" --token-fd 3 \
          3< <(printf %s "$TOKEN") >"$work/host-$tag.out" 2>"$work/host-$tag.err" </dev/null &
        host_pid=$!
        sleep 1
        "$B" bench --addr "127.0.0.1:$port" --token-fd 3 --input none --duration-s "$seconds" \
          ${viewer[@]+"${viewer[@]}"} 3< <(printf %s "$TOKEN") >"$work/bench-$tag.json" 2>"$work/bench-$tag.err"
        stop
        line=$(python3 -I - "$work/timing-$tag.jsonl" "$work/host-$tag.err" <<'PY'
import json, re, sys
timing, err = sys.argv[1:]
frames, sizes, bits, px = 0, {}, 0, 0
try:
    for raw in open(timing):
        try:
            r = json.loads(raw)
        except ValueError:
            continue
        if "encoded_bytes" not in r:
            continue
        frames += 1
        b = r.get("encoded_bytes") or 0
        if b > 0:
            w, h = r.get("width") or 1920, r.get("height") or 1080
            sizes[f"{w}x{h}"] = sizes.get(f"{w}x{h}", 0) + 1
            bits += b * 8
            px += w * h
except OSError:
    pass
sent = sum(sizes.values())
top = max(sizes, key=sizes.get) if sizes else "-"
m = re.search(r"failed: .*", open(err).read()) if err else None
bpp = f"{bits / px:.3f}" if px else "-"
print(f"{frames} {frames - sent} {top} {bpp} {m.group(0) if m else ''}")
PY
)
        read -r frames drops picture bpp error <<<"$line"
        printf '%-34s %6s %5s %-10s %6s %s\n' "$tag" "$frames" "$drops" "$picture" "$bpp" "${error:-}"
        if [[ "$mode" == ladder && "$caps" != none ]] && { [[ "${frames:-0}" -lt 10 ]] || [[ -n "${error:-}" ]]; }; then
          echo "FAIL $tag: the ladder with a scaled viewer streamed ${frames:-0} frames ${error:-}"
          fails=$((fails + 1))
        fi
      done
    done
  done
done
echo "failures: $fails"
exit $(( fails > 0 ))
