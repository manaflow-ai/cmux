#!/usr/bin/env bash
# Time-to-connected of `cmux remote connect` (first launch, no last-good route memory) when the
# first route is black-holed and the second is a shaped link: route race on vs
# CMUX_REMOTE_ROUTE_RACE=0, on a real kernel network (two network namespaces joined by a veth
# pair, tc netem), not virtual time.
#
#   sudo cmux-tui/scripts/remote-route-race-bench.sh [CMUX_TUI_BIN] [RUNS]
#
# BIN defaults to cmux-tui/target/release/cmux-tui; RUNS (per arm) to 10. Environment:
#   RTT_MS=50 LOSS_PCT=2      shaping of route 1 (applied half to each direction, both ends)
#   TIMEOUT_S=40              a trial that has not connected by then counts as a failure
#   SEED_ORDER=alt            arms alternate within each run pair (cancels load drift)
#   KEEP=1                    keep the temp dir and the namespaces after the run
#
# Topology (all inside two namespaces this script creates and removes; nothing else on the
# machine is touched):
#   rrb-c (client) 10.77.0.1  <-- veth -->  rrb-d (daemon) 10.77.0.2 (route 0), 10.77.0.3 (route 1)
# Route 0: every packet to 10.77.0.2 is dropped by netem (loss 100 %) on the client's egress, so a
# connect hangs like a black-holed address (no RST, no ICMP). Route 1: netem delay RTT/2 plus
# LOSS% loss on each end's egress for 10.77.0.3. ARP and everything else is unshaped.
#
# One daemon (`cmux daemon start --remote --remote-ws 0.0.0.0:PORT`) listens on both addresses.
# The client is paired once over route 1 with the shaping off (an invitation bound to the client's
# device key, advertising both routes), so its known daemon carries both routes in the order
# route 0, route 1. Each trial then deletes the client's route-last-good.json (a first launch)
# and times `cmux remote connect --headless` from spawn to the first line it prints, which it
# prints once the session is connected (`runtime.info()`, after the Noise handshake and every
# lane is ready). A third arm, `floor`, makes route 0 healthy (shaped exactly like route 1, race on) so
# connect cost alone shows. Per-phase split: the client logs none, so each trial is captured with
# tcpdump in the client namespace: spawn -> first visible SYN (process start + route setup; a netem-
# dropped SYN is never seen by the tap, so on the black-holed arms this includes the wait on route 0:
# the floor arm is the clean process-start-to-first-dial number), first SYN -> SYN-ACK (the return
# leg only: the tap sits after the egress delay), SYN-ACK -> connected (upgrade + Noise + lanes).
# ARMS="on off floor" selects arms.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  exec sudo -E "$0" "$@"
fi

here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-$here/../target/release/cmux-tui}
runs=${2:-10}
rtt=${RTT_MS:-50}
loss=${LOSS_PCT:-2}
timeout_s=${TIMEOUT_S:-40}
port=47931
[ -x "$bin" ] || { echo "no cmux-tui binary at $bin (build: cargo build --release -p cmux-tui)" >&2; exit 2; }
bin=$(readlink -f "$bin")

work=$(mktemp -d /tmp/rrb.XXXXXX)
chmod 700 "$work"
daemon_pid=""
sess="rrb$$"

cleanup() {
  if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi
  pkill -f "[d]aemon start --session $sess" 2>/dev/null || true
  if [ "${KEEP:-0}" = 1 ]; then echo "kept $work and namespaces rrb-c rrb-d" >&2; return; fi
  ip netns del rrb-c 2>/dev/null || true
  ip netns del rrb-d 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# ---- network -------------------------------------------------------------------------------
ip netns add rrb-c
ip netns add rrb-d
ip link add rrb-vc type veth peer name rrb-vd
ip link set rrb-vc netns rrb-c
ip link set rrb-vd netns rrb-d
nc_() { ip netns exec rrb-c "$@"; }
nd_() { ip netns exec rrb-d "$@"; }
nc_ ip link set lo up
nd_ ip link set lo up
nc_ ip addr add 10.77.0.1/24 dev rrb-vc
nd_ ip addr add 10.77.0.2/24 dev rrb-vd
nd_ ip addr add 10.77.0.3/24 dev rrb-vd
nc_ ip link set rrb-vc up
nd_ ip link set rrb-vd up
nc_ ethtool -K rrb-vc gso off tso off gro off >/dev/null 2>&1 || true
nd_ ethtool -K rrb-vd gso off tso off gro off >/dev/null 2>&1 || true
nc_ ping -c1 -W2 10.77.0.3 >/dev/null

half=$(python3 -c 'import sys; print(float(sys.argv[1]) / 2)' "$rtt")

# shape DEV MATCH(src|dst) BLACKHOLE_IP SHAPED_IP: prio qdisc, band 2 black hole, band 3 shaped.
shape() {
  local ns=$1 dev=$2 dir=$3 hole=$4 slow=$5
  ip netns exec "$ns" tc qdisc add dev "$dev" root handle 1: prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  if [ -n "$hole" ]; then
    ip netns exec "$ns" tc qdisc add dev "$dev" parent 1:2 handle 20: netem loss 100%
    ip netns exec "$ns" tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 match ip "$dir" "$hole"/32 flowid 1:2
  fi
  ip netns exec "$ns" tc qdisc add dev "$dev" parent 1:3 handle 30: netem delay "${half}ms" loss "${loss}%" limit 100000
  ip netns exec "$ns" tc filter add dev "$dev" parent 1: protocol ip prio 2 u32 match ip "$dir" "$slow"/32 flowid 1:3
}

# ---- daemon and pairing (unshaped) --------------------------------------------------------
export XDG_RUNTIME_DIR=
unset XDG_RUNTIME_DIR
dh="$work/dhome"; ch="$work/chome"; dstate="$work/dstate"; cstate="$work/cstate"
mkdir -m 700 "$dh" "$ch" "$dstate" "$cstate"

nd_ env HOME="$dh" XDG_STATE_HOME="$dh/state" XDG_CONFIG_HOME="$dh/config" \
  "$bin" daemon start --session "$sess" --remote --remote-ws "0.0.0.0:$port" \
  --remote-ws-insecure-bind --remote-state-dir "$dstate" >"$work/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
  nd_ ss -ltn 2>/dev/null | grep -q ":$port " && break
  sleep 0.2
done
nd_ ss -ltn 2>/dev/null | grep -q ":$port " || { echo "daemon did not start:" >&2; cat "$work/daemon.log" >&2; exit 3; }

cenv=(env HOME="$ch" XDG_STATE_HOME="$ch/state" XDG_CONFIG_HOME="$ch/config")
key=$("${cenv[@]}" "$bin" remote device-key --state-dir "$cstate" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')
r0="ws://10.77.0.2:$port/v1/link"
r1="ws://10.77.0.3:$port/v1/link"
invite=$(nd_ env HOME="$dh" XDG_STATE_HOME="$dh/state" XDG_CONFIG_HOME="$dh/config" \
  "$bin" remote enroll create --session "$sess" --state-dir "$dstate" --device-key "$key" \
  --advertise "$r0" --advertise "$r1" | grep -m1 '^cmux://enroll/')
printf '%s\n' "$invite" >"$work/invite"
chmod 600 "$work/invite"
# Pair over route 0 (explicit, so it stays first in the known daemon), shaping not yet on;
# the invitation's hints add route 1.
pair_out=$(nc_ "${cenv[@]}" timeout 60 "$bin" remote connect "$r0" --invite-file "$work/invite" \
  --headless --state-dir "$cstate" 2>"$work/pair.err" | head -1) || true
[ -n "$pair_out" ] || { echo "pairing failed:" >&2; cat "$work/pair.err" >&2; exit 4; }
sleep 1
nc_ "${cenv[@]}" "$bin" remote known-daemons --state-dir "$cstate" >"$work/known.txt" 2>&1 || true
grep -q "10.77.0.2" "$work/known.txt" && grep -q "10.77.0.3" "$work/known.txt" ||
  { echo "paired daemon lacks both routes:" >&2; cat "$work/known.txt" >&2; exit 5; }

shape rrb-c rrb-vc dst 10.77.0.2 10.77.0.3
# The daemon's replies leave from 10.77.0.3, so its egress matches on source.
shape rrb-d rrb-vd src "" 10.77.0.3
# Route 0's replies get the same shaping, used only by the floor arm (the client's egress drops it otherwise).
ip netns exec rrb-d tc filter add dev rrb-vd parent 1: protocol ip prio 3 u32 match ip src 10.77.0.2/32 flowid 1:3
set_route0() { # hole|shaped
  if [ "$1" = hole ]; then
    nc_ tc qdisc change dev rrb-vc parent 1:2 handle 20: netem loss 100%
  else
    nc_ tc qdisc change dev rrb-vc parent 1:2 handle 20: netem delay "${half}ms" loss "${loss}%" limit 100000
  fi
}

# ---- trials ---------------------------------------------------------------------------------
export BENCH_BIN="$bin" BENCH_CSTATE="$cstate" BENCH_CHOME="$ch" BENCH_TIMEOUT="$timeout_s"
trial() { # ARM(on|off|floor) -> "ms spawn_to_syn syn_to_synack synack_to_connected" or "FAIL"
  if [ "$1" = floor ]; then set_route0 shaped; else set_route0 hole; fi
  nc_ python3 - "$1" <<'PY'
import os, signal, subprocess, sys, time
arm = sys.argv[1]
state = os.environ["BENCH_CSTATE"]
try:
    os.unlink(os.path.join(state, "client", "route-last-good.json"))
except FileNotFoundError:
    pass
env = dict(os.environ, HOME=os.environ["BENCH_CHOME"],
           XDG_STATE_HOME=os.environ["BENCH_CHOME"] + "/state",
           XDG_CONFIG_HOME=os.environ["BENCH_CHOME"] + "/config")
env.pop("CMUX_REMOTE_ROUTE_RACE", None)
if arm == "off":
    env["CMUX_REMOTE_ROUTE_RACE"] = "0"
cap = subprocess.Popen(["tcpdump", "-i", "any", "-tt", "-n", "-l", "-Q", "inout", "host", "10.77.0.2", "or", "arp", "or", "port", "47931"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
time.sleep(0.4)
w0 = time.time()
t0 = time.monotonic()
p = subprocess.Popen([os.environ["BENCH_BIN"], "remote", "connect", "--headless",
                      "--state-dir", state],
                     env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     start_new_session=True)
import select
ready, _, _ = select.select([p.stdout], [], [], float(os.environ["BENCH_TIMEOUT"]))
line = p.stdout.readline() if ready else b""
dt = (time.monotonic() - t0) * 1000
wend = w0 + dt / 1000
try:
    os.killpg(p.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
try:
    p.wait(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
cap.terminate()
out = cap.stdout.read()
if os.environ.get("BENCH_DEBUG"):
    sys.stderr.write(out)
syn = synack = None
for l in out.splitlines():
    f = l.split()
    if len(f) < 7 or "Flags" not in l:
        continue
    ts = float(f[0])
    if "Flags [S]," in l and syn is None:
        syn = ts
    if "Flags [S.]," in l and synack is None:
        synack = ts
if line.strip() and syn and synack:
    print(f"{dt:.0f} {(syn - w0) * 1000:.0f} {(synack - syn) * 1000:.0f} {(wend - synack) * 1000:.0f}")
elif line.strip():
    print(f"{dt:.0f} - - -")
else:
    print("FAIL")
PY
}

load_start=$(cut -d" " -f1-3 /proc/loadavg)
results="$work/results.tsv"
: >"$results"
for i in $(seq 1 "$runs"); do
  read -ra order <<<"${ARMS:-on off floor}"
  # rotate the arm order each run so no arm always goes first
  for ((k=0; k<${#order[@]}; k++)); do
    arm=${order[$(( (k + i) % ${#order[@]} ))]}
    ms=$(trial "$arm")
    printf '%s\t%s\t%s\n' "$arm" "$i" "${ms// /$'\t'}" >>"$results"
    echo "run $i arm=$arm connect_ms,spawn>syn,syn>synack,synack>connected=$ms" >&2
  done
done

echo "load average at start: $load_start; at end: $(cut -d" " -f1-3 /proc/loadavg) (1/5/15 min)"
python3 - "$results" "$rtt" "$loss" "$runs" <<'PY'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()]
rtt, loss, runs = sys.argv[2:5]
def pct(v, q):
    v = sorted(v)
    k = (len(v) - 1) * q
    lo = int(k); hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)
print(f"route 0 black-holed (netem loss 100%) except the floor arm (route 0 shaped like route 1); route 1 {rtt} ms RTT / {loss}% loss; first launch, no last-good memory; N={runs} per arm")
print(f"{'arm':<28}{'N':>3}{'ok':>4}{'min':>7}{'p50':>7}{'p95':>7}{'max':>7}   p50 phases ms: spawn>SYN  SYN>SYNACK  SYNACK>connected")
for arm, name in (("on", "race on (default)"), ("off", "CMUX_REMOTE_ROUTE_RACE=0"), ("floor", "floor: route 0 healthy, race")):
    sel = [r for r in rows if r[0] == arm]
    if not sel:
        continue
    v = [float(r[2]) for r in sel if r[2] != "FAIL"]
    ph = [[float(x) for x in r[3:6]] for r in sel if r[2] != "FAIL" and len(r) > 5 and r[3] != "-"]
    phs = "  ".join(f"{pct([p[i] for p in ph], .5):>9.0f}" for i in range(3)) if ph else "-"
    if v:
        print(f"{name:<28}{len(sel):>3}{len(v):>4}{min(v):>7.0f}{pct(v,.5):>7.0f}{pct(v,.95):>7.0f}{max(v):>7.0f}   {phs}")
    else:
        print(f"{name:<28}{len(sel):>3}{0:>4}")
PY
