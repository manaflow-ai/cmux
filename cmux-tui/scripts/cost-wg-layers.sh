#!/usr/bin/env bash
# Per-layer cost of cmux-wg's userspace path (wg-tcp) against kernel TCP (tcp)
# on clean loopback, one harness, one machine. Run from the repo root on Linux:
#   cmux-ci test --timeout 3600 -- 'bash cmux-tui/scripts/cost-wg-layers.sh'
# Every run is in a private network namespace with lo at MTU 1500 and no
# segmentation offload (as remote-stream-netem-bench.sh), so lo's rx_packets
# counts wire-size packets for both paths. A second kernel TCP row keeps the
# offloads on (TSO/GSO/GRO), the kernel's real advantage.
# Prints COST_* lines and a Markdown summary at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
mkdir -p "$out"

sudo -n apt-get update -qq >/dev/null || true
sudo -n apt-get install -y -qq --no-install-recommends strace ethtool iproute2 time procps >/dev/null
sudo -n apt-get install -y -qq --no-install-recommends "linux-tools-$(uname -r)" >/dev/null 2>&1 \
  || sudo -n apt-get install -y -qq --no-install-recommends linux-tools-generic linux-tools-common >/dev/null 2>&1 || true
perf_bin=$(command -v perf || true)
if ! "${perf_bin:-false}" --version >/dev/null 2>&1; then
  perf_bin=$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | tail -1 || true)
fi
echo "COST_PERF=${perf_bin:-none} kernel=$(uname -r) nproc=$(nproc)"
lscpu | grep -E 'Model name|^CPU\(s\)' || true

cargo build --release --locked -p cmux-wg --example remote_stream_bench
bin="${CARGO_TARGET_DIR:-$PWD/target}/release/examples/remote_stream_bench"
cp "$bin" "$out/bench"

cat > "$out/inner.sh" <<'INNER'
set -uo pipefail
out=$1 perf=$2
bin=$out/bench
ip link set lo up
lo_counts() { echo "$(cat /sys/class/net/lo/statistics/rx_packets) $(cat /sys/class/net/lo/statistics/rx_bytes)"; }
offload() { ethtool -K lo gso "$1" tso "$1" gro "$1" >/dev/null 2>&1 || true; }
ip link set lo mtu 1500
spec=(--fps 60 --frame-bytes 3500 --keyframe-bytes 200000)
# name path offload seconds bulk [wrapper...]
run() {
  local name=$1 path=$2 off=$3 secs=$4 bulk=$5; shift 5
  offload "$off"
  local before after
  before=$(lo_counts)
  /usr/bin/time -f '%e %U %S' -o "$out/$name.time" "$@" "$bin" --path "$path" --seconds "$secs" \
    "${spec[@]}" --bulk-bytes "$bulk" > "$out/$name.json" 2>"$out/$name.err" &
  local pid=$! target
  sleep 2
  # Threads of the bench itself (newest process running the binary).
  target=$(pgrep -n -f "^$bin --path $path" || echo "$pid")
  ls "/proc/$target/task" 2>/dev/null | wc -l > "$out/$name.threads"
  wait "$pid"
  after=$(lo_counts)
  echo "COST_RUN name=$name path=$path offload=$off seconds=$secs bulk=$bulk lo_before=[$before] lo_after=[$after] time=[$(tail -1 "$out/$name.time")] threads=$(cat "$out/$name.threads") result=$(cat "$out/$name.json")"
  echo "$before $after" > "$out/$name.lo"
}
for path in tcp wg-tcp; do
  # 1. The spec workload, plain: CPU, packets, threads.
  run "$path.spec" "$path" off 8 4000000
  # 2. Stream only, and a long bulk on a 1 s stream (CPU per Mbit/s = bulk minus base).
  run "$path.base" "$path" off 1 0
  run "$path.bulk" "$path" off 1 200000000
  # 3. Syscalls on the spec workload.
  run "$path.strace" "$path" off 8 4000000 strace -c -f -o "$out/$path.strace.txt"
  # 4. Profiles: spec workload and bulk.
  if [ -n "$perf" ]; then
    run "$path.perfspec" "$path" off 8 4000000 "$perf" record -F 2999 -o "$out/$path.spec.perf" --
    run "$path.perfbulk" "$path" off 1 200000000 "$perf" record -F 2999 -o "$out/$path.bulk.perf" --
    for kind in spec bulk; do
      "$perf" report -i "$out/$path.$kind.perf" --no-children --sort comm,dso,sym --stdio -q --percent-limit 0.2 > "$out/$path.$kind.sym.txt" 2>/dev/null
    done
  fi
done
# Kernel TCP with its offloads, for reference.
run "tcp-offload.bulk" tcp on 1 200000000
run "tcp-offload.base" tcp on 1 0
INNER

sudo -n unshare -n bash "$out/inner.sh" "$out" "${perf_bin:-}" | tee "$out/runs.txt"
sudo -n chown -R "$(id -u)" "$out" || true

for f in "$out"/*.strace.txt; do echo "== $f"; head -40 "$f"; done
for f in "$out"/*.sym.txt; do echo "== $f"; grep -v '^$' "$f" | head -45; done

python3 - "$out" <<'PY'
import json, re, sys, os, glob
out = sys.argv[1]
def load(name):
    p = f"{out}/{name}"
    if not os.path.exists(p + ".json"): return None
    try: res = json.load(open(p + ".json"))
    except Exception: res = {}
    lo = list(map(int, open(p + ".lo").read().split()))
    t = open(p + ".time").read().split()[-3:]
    real, user, sys_ = map(float, t)
    return dict(res=res, pkts=lo[2]-lo[0], bytes=lo[3]-lo[1], real=real, cpu=user+sys_, user=user, sys=sys_,
                threads=int(open(p + ".threads").read().strip() or 0))
SEND = {"sendto","sendmsg","sendmmsg","write","writev","pwrite64"}
RECV = {"recvfrom","recvmsg","recvmmsg","read","readv","pread64"}
def strace(path):
    calls = {}
    f = f"{out}/{path}.strace.txt"
    if not os.path.exists(f): return calls
    for line in open(f):
        parts = line.split()
        if len(parts) >= 5 and re.match(r"^[\d.]+$", parts[0]) and parts[-1] != "total":
            calls[parts[-1]] = int(parts[3])
    return calls
def buckets(path, kind):
    f = f"{out}/{path}.{kind}.sym.txt"
    b = {"crypto (chacha20poly1305/boringtun)":0,"smoltcp stack":0,"kernel":0,"tokio runtime/sync":0,"memcpy/alloc":0,"other user":0}
    total = 0
    if not os.path.exists(f): return b, 0
    for line in open(f):
        m = re.match(r"\s*([\d.]+)%\s+(\S+)\s+(\S+)\s+\[(.)\]\s+(.*)", line)
        if not m: continue
        pct, comm, dso, mode, sym = float(m[1]), m[2], m[3], m[4], m[5]
        if "bench" not in comm and "tokio" not in comm and "remote" not in comm: continue
        total += pct
        s = sym.lower()
        if mode == "k": b["kernel"] += pct
        elif re.search(r"chacha|poly1305|boringtun|aead|x25519|blake2", s): b["crypto (chacha20poly1305/boringtun)"] += pct
        elif "smoltcp" in s: b["smoltcp stack"] += pct
        elif re.search(r"tokio|futex|parking|mpsc|notify|waker|crossbeam", s): b["tokio runtime/sync"] += pct
        elif re.search(r"memcpy|memmove|malloc|free|alloc|realloc|bytes::", s): b["memcpy/alloc"] += pct
        else: b["other user"] += pct
    return b, total
rows = []
print("\n## COST_SUMMARY\n")
print("| metric | tcp | wg-tcp |\n|---|---|---|")
data = {p: {k: load(f"{p}.{k}") for k in ("spec","base","bulk","strace")} for p in ("tcp","wg-tcp")}
def cell(p, fn):
    try: return fn(data[p])
    except Exception as e: return f"n/a ({type(e).__name__})"
def line(label, fn): print(f"| {label} | {cell('tcp', fn)} | {cell('wg-tcp', fn)} |")
line("spec: input_to_photon_ms / bulk_mbit_s", lambda d: f"{d['spec']['res'].get('input_to_photon_ms')} / {d['spec']['res'].get('bulk_mbit_s')}")
line("spec: lo packets (MTU 1500, no offload)", lambda d: d['spec']['pkts'])
line("spec: CPU s (user+sys) / wall s", lambda d: f"{d['spec']['cpu']:.2f} ({d['spec']['user']:.2f}+{d['spec']['sys']:.2f}) / {d['spec']['real']:.2f}")
line("spec: CPU us per packet", lambda d: f"{d['spec']['cpu']/d['spec']['pkts']*1e6:.1f}")
for p in ("tcp","wg-tcp"):
    c = strace(p); pk = data[p]['strace']['pkts'] if data[p]['strace'] else 0
    data[p]['sc'] = dict(send=sum(v for k,v in c.items() if k in SEND), recv=sum(v for k,v in c.items() if k in RECV),
        total=sum(c.values()), pk=pk, top=sorted(c.items(), key=lambda kv:-kv[1])[:6])
line("strace: syscalls/packet send", lambda d: f"{d['sc']['send']/d['sc']['pk']:.2f}")
line("strace: syscalls/packet recv", lambda d: f"{d['sc']['recv']/d['sc']['pk']:.2f}")
line("strace: syscalls/packet all", lambda d: f"{d['sc']['total']/d['sc']['pk']:.2f}")
line("strace: top calls", lambda d: ", ".join(f"{k} {v}" for k,v in d['sc']['top']))
line("threads (spec run)", lambda d: d['spec']['threads'])
def bulkcost(d):
    b, base, mbit = d['bulk'], d['base'], d['bulk']['res']['bulk_mbit_s']
    wall = 200e6*8/1e6/mbit
    cpu = b['cpu'] - base['cpu']
    return f"{mbit:.0f} Mbit/s, {cpu:.2f} CPU s over {wall:.2f} s = {cpu/wall*100:.0f}% -> {cpu/wall*100/mbit:.3f} %CPU per Mbit/s; {b['pkts']-base['pkts']} pkts, {cpu/max(1,b['pkts']-base['pkts'])*1e6:.2f} us/pkt"
line("bulk 200 MB: CPU% per Mbit/s", bulkcost)
for kind in ("spec","bulk"):
    for p in ("tcp","wg-tcp"):
        data[p][kind+"_prof"] = buckets(p, kind)
    keys = list(data["tcp"][kind+"_prof"][0].keys())
    for k in keys:
        line(f"perf {kind}: {k} % of bench samples", lambda d, k=k, kind=kind: f"{d[kind+'_prof'][0][k]/d[kind+'_prof'][1]*100:.1f}" if d[kind+'_prof'][1] else "n/a")
try:
    ob, obase = load("tcp-offload.bulk"), load("tcp-offload.base")
    mbit = ob['res']['bulk_mbit_s']; wall = 200e6*8/1e6/mbit; cpu = ob['cpu']-obase['cpu']
    print(f"\nkernel TCP with TSO/GSO/GRO on: {mbit:.0f} Mbit/s, {cpu/wall*100/mbit:.4f} %CPU per Mbit/s, {ob['pkts']-obase['pkts']} lo packets")
except Exception as e:
    print("offload row n/a", e)
PY
