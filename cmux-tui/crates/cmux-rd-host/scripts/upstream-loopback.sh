#!/usr/bin/env bash
# Upstream media loopback check on Linux with Xvfb (rd change C4): the bench sends synthetic
# microphone, camera and screen frames upstream the way the viewer app does, and a host
# started with --upstream-record DIR must record every sent frame whole and in order (same
# frame count, byte count and FNV-1a hash), over both carriers. A host without the flag must
# refuse stream_open with "caps". Run from the crate directory's parent after
# `cargo build --release` in this crate. Exit 0 only when every check passes.
set -u
cd "$(dirname "$0")/.."
B=$PWD/target/release/cmux-rd
FRAMES=${FRAMES:-200}
WORK=$(mktemp -d /tmp/rd-upstream.XXXXXX)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
command -v Xvfb >/dev/null || sudo apt-get install -y -qq xvfb >/dev/null 2>&1
# Waits (bounded) until FILE contains PATTERN; the host and Xvfb print a line when ready.
wait_for() {
  local file=$1 pattern=$2
  timeout 20 bash -c "until grep -q '$pattern' '$file' 2>/dev/null; do sleep 0.05; done"
}
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
DISPLAY_NUM=$(( 90 + RANDOM % 9 ))
Xvfb ":$DISPLAY_NUM" -screen 0 1280x720x24 -nolisten tcp -displayfd 1 >"$WORK/xvfb.out" 2>"$WORK/xvfb.log" &
PIDS+=($!)
wait_for "$WORK/xvfb.out" . || { echo "FAIL: Xvfb did not start"; exit 1; }
"$B" testapp --display ":$DISPLAY_NUM" --workload marker >"$WORK/app.log" 2>&1 &
PIDS+=($!)
"$B" host --owner owner --display ":$DISPLAY_NUM" --port 4105 --profile baseline \
  --upstream-record "$WORK/rec" --token-fd 3 3< <(printf %s "$TOKEN") >"$WORK/host.log" 2>&1 &
PIDS+=($!)
"$B" host --owner owner --display ":$DISPLAY_NUM" --port 4106 --profile baseline \
  --token-fd 3 3< <(printf %s "$TOKEN") >"$WORK/host-nosink.log" 2>&1 &
PIDS+=($!)
wait_for "$WORK/host.log" "listening on" || { echo "FAIL: recording host did not start"; cat "$WORK/host.log"; exit 1; }
wait_for "$WORK/host-nosink.log" "listening on" || { echo "FAIL: default host did not start"; exit 1; }

fail=0
run() {
  local name=$1 port=$2 carrier=$3 which=$4
  timeout 60 "$B" bench --addr "127.0.0.1:$port" --carrier "$carrier" --samples 0 --user owner \
    --upstream "$which" --upstream-frames "$FRAMES" --token-fd 3 3< <(printf %s "$TOKEN") \
    >"$WORK/$name.out" 2>"$WORK/$name.err"
}

# A host without a sink offers no up_media: stream_open is refused with "caps".
if run nosink 4106 stream mic; then
  echo "FAIL nosink: the default host accepted an upstream stream"; fail=1
elif grep -q 'refused by the host: caps' "$WORK/nosink.err"; then
  echo "PASS nosink: refused (caps)"
else
  echo "FAIL nosink: $(cat "$WORK/nosink.err")"; fail=1
fi

recorded=0
for spec in mic:udp camera:stream screen:udp mic:stream; do
  which=${spec%%:*} carrier=${spec##*:} name="$which-$carrier"
  run "$name" 4105 "$carrier" "$which" || { echo "FAIL $name: $(tail -2 "$WORK/$name.err")"; fail=1; continue; }
  # The host logs one upstream_recorded line per closed stream, in session order, when it
  # handles the bench's stream_close (after the bench exits).
  recorded=$((recorded + 1))
  timeout 10 bash -c "until [ \$(grep -c upstream_recorded '$WORK/host.log') -ge $recorded ]; do sleep 0.05; done" \
    || { echo "FAIL $name: the host logged no upstream_recorded line"; fail=1; continue; }
  grep '"upstream_recorded"' "$WORK/host.log" | sed -n "${recorded}p" >"$WORK/$name.host"
  if python3 -I - "$WORK/$name.out" "$WORK/$name.host" "$FRAMES" <<'PY'
import json, sys
sent = next(json.loads(l)["upstream"] for l in open(sys.argv[1]) if '"upstream"' in l and '"g2g_ms"' not in l)
rec = json.loads(open(sys.argv[2]).read())["upstream_recorded"]
frames = int(sys.argv[3])
size = __import__("os").path.getsize(rec["path"])
# Audio packets are stored after a 2-byte length.
expected_size = rec["bytes"] + (2 * rec["frames"] if rec["kind"] == "UpAudio" else 0)
checks = {
    "all frames sent": sent["frames_sent"] == frames,
    "all acked": sent["all_acked"],
    "frames match": rec["frames"] == sent["frames_sent"],
    "bytes match": rec["bytes"] == sent["bytes_sent"],
    "hash match": rec["fnv1a"] == sent["fnv1a"],
    "file size": size == expected_size,
    "no write error": rec["error"] is None,
}
print(json.dumps({"sent": sent, "recorded": rec, "checks": checks}))
sys.exit(0 if all(checks.values()) else 1)
PY
  then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi
done
grep -v audit "$WORK/host.log" | grep -v upstream_recorded | tail -4
echo "work dir: $WORK"
exit $fail
