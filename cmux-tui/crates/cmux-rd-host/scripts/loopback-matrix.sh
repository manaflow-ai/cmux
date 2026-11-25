#!/usr/bin/env bash
# Loopback glass-to-glass matrix on Linux with Xvfb: for each resolution (RESES) and testapp
# workload (WORKLOADS), one host and a marker bench per carrier (CARRIERS), then one table row each:
# g2g p50/p95/p99 ms, frames/s, Mbit/s, lost, decode p50. Builds the bench binary first. Run from
# this crate (cmux-tui/crates/cmux-rd-host); reports land in $OUT (default $FAST_CHECKS_OUT or /tmp/rd-matrix).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-${FAST_CHECKS_OUT:-/tmp/rd-matrix}}
mkdir -p "$OUT"
exec > >(tee "$OUT/matrix.txt") 2>&1
command -v Xvfb >/dev/null || sudo apt-get install -y -qq xvfb >/dev/null 2>&1
# The feature set CI builds (.github/rust-workspaces.toml): bench without libpipewire.
cargo build --release --no-default-features --features bench,link,portal-dbus -q || exit 1
B=${CARGO_TARGET_DIR:-$PWD/target}/release/cmux-rd
fails=0
$B --help >/dev/null && echo "cmux-rd --help: exit 0" || { echo "FAIL cmux-rd --help"; fails=1; }
pids=()
stop() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; pids=(); }
trap stop EXIT
TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '%-10s %-7s %-7s %7s %7s %7s %7s %7s %5s %7s\n' res workload carrier p50 p95 p99 fps mbit lost dec50
for res in ${RESES:-1920x1080 2560x1440 3840x2160}; do
  for wl in ${WORKLOADS:-marker motion}; do
    Xvfb :97 -screen 0 "${res}x24" -nolisten tcp >"$OUT/xvfb.log" 2>&1 & pids+=($!)
    sleep 1
    kill -0 "${pids[-1]}" 2>/dev/null || { echo "FAIL $res: Xvfb :97 did not start: $(tail -2 "$OUT/xvfb.log")"; fails=$((fails+1)); stop; continue; }
    $B testapp --display :97 --workload "$wl" >"$OUT/app-$res-$wl.log" 2>&1 & pids+=($!)
    sleep 1
    $B host --owner owner --display :97 --port 4103 --profile baseline ${HOSTARGS:-} --token-fd 3 \
      3< <(printf %s "$TOKEN") >"$OUT/host-$res-$wl.log" 2>&1 & pids+=($!)
    sleep 2
    for c in ${CARRIERS:-udp stream}; do
      f="$OUT/bench-$res-$wl-$c.json"
      timeout 300 $B bench --addr 127.0.0.1:4103 --carrier "$c" --samples "${N:-200}" --user owner \
        --token-fd 3 3< <(printf %s "$TOKEN") >"$f" 2>"$f.err" || { echo "FAIL $res $wl $c: $(tail -2 "$f.err")"; fails=$((fails+1)); }
      python3 - "$f" "$res" "$wl" "$c" <<'PY'
import json, sys
f, res, wl, c = sys.argv[1:]
try:
    r = json.loads(open(f).read().strip().splitlines()[-1])
except Exception as e:
    print(f"{res:10} {wl:7} {c:7} no report ({e})"); sys.exit()
g, d = r.get("g2g_ms") or {}, r.get("decode_ms") or {}
n = lambda x: "-" if x is None else f"{x:.1f}"
print(f"{res:10} {wl:7} {c:7} {n(g.get('p50')):>7} {n(g.get('p95')):>7} {n(g.get('p99')):>7} "
      f"{n(r.get('frames_per_s')):>7} {n(r.get('mbit_per_s')):>7} {r.get('lost', '-'):>5} {n(d.get('p50')):>7}")
PY
    done
    grep -v audit "$OUT/host-$res-$wl.log" | tail -3
    stop
  done
done
echo "failures: $fails"
exit $(( fails > 0 ))
