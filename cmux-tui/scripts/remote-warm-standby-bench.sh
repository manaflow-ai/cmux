#!/usr/bin/env bash
# Time-to-reconnected of `cmux remote connect` after the live route is black-holed mid-session, with
# the warm standby route (default) vs CMUX_REMOTE_WARM_STANDBY=0, over iroh direct on a real kernel
# network (network namespaces, veth, tc netem), not virtual time. Needs a binary built with
# `--features iroh-transport`.
#
#   sudo cmux-tui/scripts/remote-warm-standby-bench.sh [CMUX_TUI_BIN] [RUNS]
#
# Environment: RTT_MS=50 LOSS_PCT=2 (both routes, half per direction, both ends), SETTLE_S=8 (wait
# after the link is up so the standby has dialed), TIMEOUT_S=90, ARMS="after before" (after =
# default, before = CMUX_REMOTE_WARM_STANDBY=0), KEEP=1, BENCH_DEBUG=1.
#
# Topology: rwb-c (client) and rwb-d (daemon) joined by TWO veth pairs, one per route, each on its
# own subnet: route 0 10.77.0.1 <-> 10.77.0.2, route 1 10.77.1.1 <-> 10.77.1.2. Two links, because the
# daemon's one iroh UDP socket (0.0.0.0) answers from the egress interface's address; one address per
# link keeps each route's replies on its own path. The daemon runs `daemon start --remote --iroh`
# (no relay, no ws) and the client dials with `--iroh-path direct-only`. The two routes are
# iroh://NODE?direct_addrs=<link address>:PORT, the same node reached over each link.
#
# Trial: delete route-last-good.json, start `remote connect --headless --json` (route 0 is first,
# so the link comes up on it), wait SETTLE_S, then t_bh: netem loss 100 % on both ends of route 0's
# veth. Reconnected = the first connection-snapshot (or any later output line) after t_bh showing
# the link on route 1, i.e. the client reports a transport selected path on route 1's address. A
# tcpdump on the client's route 1 veth splits the interval at the first datagram of a new
# handshake there (a dial) when the standby is cold.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  exec sudo -E "$0" "$@"
fi

here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-$here/../target/release/cmux-tui}
runs=${2:-10}
rtt=${RTT_MS:-50}
loss=${LOSS_PCT:-2}
settle=${SETTLE_S:-8}
timeout_s=${TIMEOUT_S:-90}
[ -x "$bin" ] || { echo "no cmux-tui binary at $bin (build: cargo build --release -p cmux-tui --features iroh-transport)" >&2; exit 2; }
bin=$(readlink -f "$bin")

work=$(mktemp -d /tmp/rwb.XXXXXX)
chmod 700 "$work"
daemon_pid=""
sess="rwb$$"

cleanup() {
  if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi
  if [ "${KEEP:-0}" = 1 ]; then echo "kept $work and namespaces rwb-c rwb-d" >&2; return; fi
  ip netns del rwb-c 2>/dev/null || true
  ip netns del rwb-d 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

ip netns add rwb-c
ip netns add rwb-d
nc_() { ip netns exec rwb-c "$@"; }
nd_() { ip netns exec rwb-d "$@"; }
for n in 0 1; do
  ip link add "rwb-c$n" type veth peer name "rwb-d$n"
  ip link set "rwb-c$n" netns rwb-c
  ip link set "rwb-d$n" netns rwb-d
  nc_ ip addr add "10.77.$n.1/24" dev "rwb-c$n"
  nd_ ip addr add "10.77.$n.2/24" dev "rwb-d$n"
  nc_ ip link set "rwb-c$n" up
  nd_ ip link set "rwb-d$n" up
  nc_ ethtool -K "rwb-c$n" gso off tso off gro off >/dev/null 2>&1 || true
  nd_ ethtool -K "rwb-d$n" gso off tso off gro off >/dev/null 2>&1 || true
done
nc_ ip link set lo up
nd_ ip link set lo up
nc_ ping -c1 -W2 10.77.0.2 >/dev/null
nc_ ping -c1 -W2 10.77.1.2 >/dev/null
half=$(python3 -c 'import sys; print(float(sys.argv[1]) / 2)' "$rtt")

# link_state N shaped|hole: both ends of route N's veth.
link_state() {
  local n=$1 state=$2 spec
  if [ "$state" = hole ]; then spec="loss 100%"; else spec="delay ${half}ms loss ${loss}% limit 100000"; fi
  for side in c d; do
    ip netns exec "rwb-$side" tc qdisc replace dev "rwb-$side$n" root netem $spec
  done
}

export XDG_RUNTIME_DIR=
unset XDG_RUNTIME_DIR
dh="$work/dhome"; ch="$work/chome"; dstate="$work/dstate"; cstate="$work/cstate"
mkdir -m 700 "$dh" "$ch" "$dstate" "$cstate"
denv=(env HOME="$dh" XDG_STATE_HOME="$dh/state" XDG_CONFIG_HOME="$dh/config")
cenv=(env HOME="$ch" XDG_STATE_HOME="$ch/state" XDG_CONFIG_HOME="$ch/config")

nd_ "${denv[@]}" "$bin" daemon start --session "$sess" --remote --iroh \
  --remote-state-dir "$dstate" >"$work/daemon.log" 2>&1 &
daemon_pid=$!
# The admin socket appears once iroh has bound (it waits for a relay that never comes in a netns).
for _ in $(seq 1 180); do
  ls "$dstate"/sessions/*/admin.sock >/dev/null 2>&1 && break
  sleep 1
done
ls "$dstate"/sessions/*/admin.sock >/dev/null 2>&1 || { echo "daemon did not start:" >&2; cat "$work/daemon.log" >&2; exit 3; }

key=$("${cenv[@]}" "$bin" remote device-key --state-dir "$cstate" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')
probe=$(nd_ "${denv[@]}" "$bin" remote enroll create --session "$sess" --state-dir "$dstate" --device-key "$key" 2>&1 | grep -m1 "  cmux remote connect iroh://")
node=$(printf '%s' "$probe" | sed -n 's|.*iroh://\([0-9a-f]*\).*|\1|p')
port=$(nd_ ss -lunH | awk '{print $4}' | grep '^0.0.0.0:' | head -1 | cut -d: -f2)
[ -n "$node" ] && [ -n "$port" ] || { echo "no iroh node id/port (node=$node port=$port)" >&2; exit 4; }
r0="iroh://$node?direct_addrs=10.77.0.2%3A$port"
r1="iroh://$node?direct_addrs=10.77.1.2%3A$port"
invite=$(nd_ "${denv[@]}" "$bin" remote enroll create --session "$sess" --state-dir "$dstate" --device-key "$key" \
  --advertise "$r0" --advertise "$r1" | grep -m1 '^cmux://enroll/')
printf '%s\n' "$invite" >"$work/invite"
chmod 600 "$work/invite"
pair_out=$(nc_ "${cenv[@]}" timeout 90 "$bin" remote connect "$r0" --iroh-path direct-only --invite-file "$work/invite" \
  --headless --state-dir "$cstate" 2>"$work/pair.err" | head -1) || true
[ -n "$pair_out" ] || { echo "pairing failed:" >&2; cat "$work/pair.err" >&2; exit 5; }
sleep 1
nc_ "${cenv[@]}" "$bin" remote known-daemons --state-dir "$cstate" >"$work/known.txt" 2>&1 || true
grep -q "10.77.0.2" "$work/known.txt" && grep -q "10.77.1.2" "$work/known.txt" ||
  { echo "paired daemon lacks both routes:" >&2; cat "$work/known.txt" >&2; exit 6; }

link_state 0 shaped
link_state 1 shaped

export BENCH_BIN="$bin" BENCH_CSTATE="$cstate" BENCH_CHOME="$ch" BENCH_TIMEOUT="$timeout_s" BENCH_SETTLE="$settle"
trial() { # ARM(after|before) -> "reconnect_ms detect_ms dial_ms" or "FAIL"
  link_state 0 shaped
  nc_ python3 - "$1" <<'PY'
import json, os, select, signal, subprocess, sys, time
arm = sys.argv[1]
state = os.environ["BENCH_CSTATE"]
try:
    os.unlink(os.path.join(state, "client", "route-last-good.json"))
except FileNotFoundError:
    pass
env = dict(os.environ, HOME=os.environ["BENCH_CHOME"],
           XDG_STATE_HOME=os.environ["BENCH_CHOME"] + "/state",
           XDG_CONFIG_HOME=os.environ["BENCH_CHOME"] + "/config")
env.pop("CMUX_REMOTE_WARM_STANDBY", None)
if arm == "before":
    env["CMUX_REMOTE_WARM_STANDBY"] = "0"
cap = subprocess.Popen(["tcpdump", "-i", "any", "-tt", "-n", "-l", "-q", "-Q", "inout", "udp"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
time.sleep(0.4)
p = subprocess.Popen([os.environ["BENCH_BIN"], "remote", "connect", "--headless", "--json",
                      "--iroh-path", "direct-only", "--state-dir", state],
                     env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     start_new_session=True, bufsize=0)
buf = b""
def lines(deadline):
    global buf
    while True:
        while b"\n" in buf:
            l, buf = buf.split(b"\n", 1)
            yield time.time(), l.decode()
        left = deadline - time.time()
        if left <= 0:
            return
        r, _, _ = select.select([p.stdout], [], [], left)
        if not r:
            return
        d = os.read(p.stdout.fileno(), 65536)
        if not d:
            return
        buf += d
def route_of(line):
    # the snapshot's selected path address: 10.77.<n>.2
    for n in (0, 1):
        if f"10.77.{n}.2" in line:
            return n
    return None
def finish():
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
t_start = time.time()
up = None
for ts, l in lines(t_start + float(os.environ["BENCH_TIMEOUT"])):
    if os.environ.get("BENCH_DEBUG"):
        sys.stderr.write(f"[{ts - t_start:7.3f}] {l[:1400]}\n")
    if route_of(l) == 0:
        up = ts
        break
if up is None:
    finish(); print("FAIL up"); sys.exit(0)
# settle: drain output while the standby dials
for ts, l in lines(time.time() + float(os.environ["BENCH_SETTLE"])):
    if os.environ.get("BENCH_DEBUG"):
        sys.stderr.write(f"[{ts - t_start:7.3f}] settle {l[:1400]}\n")
t_bh = time.time()
subprocess.run(["tc", "qdisc", "replace", "dev", "rwb-c0", "root", "netem", "loss", "100%"], check=True,
               env=dict(os.environ))
subprocess.run(["ip", "netns", "exec", "rwb-d", "tc", "qdisc", "replace", "dev", "rwb-d0", "root", "netem", "loss", "100%"], check=True)
done = None
first = None
for ts, l in lines(t_bh + float(os.environ["BENCH_TIMEOUT"])):
    if os.environ.get("BENCH_DEBUG"):
        sys.stderr.write(f"[{ts - t_bh:7.3f}] after-bh {l[:1400]}\n")
    if first is None:
        first = ts
    if route_of(l) == 1:
        done = ts
        break
finish()
cap.terminate()
if os.environ.get("BENCH_DEBUG"):
    buckets = {}
    for l in cap.stdout.read().splitlines():
        f = l.split()
        if len(f) < 4:
            continue
        key = (int((float(f[0]) - t_bh) // 1), f[1])
        buckets[key] = buckets.get(key, 0) + 1
    for (sec, dev), n in sorted(buckets.items()):
        sys.stderr.write(f"pkts t={sec:+d}s {dev} {n}\n")
if done is None:
    print("FAIL reconnect")
else:
    print(f"{(done - t_bh) * 1000:.0f} {((first or done) - t_bh) * 1000:.0f}")
PY
}

load_start=$(cut -d" " -f1-3 /proc/loadavg)
results="$work/results.tsv"
: >"$results"
for i in $(seq 1 "$runs"); do
  read -ra order <<<"${ARMS:-after before}"
  for ((k=0; k<${#order[@]}; k++)); do
    arm=${order[$(( (k + i) % ${#order[@]} ))]}
    ms=$(trial "$arm")
    printf '%s\t%s\t%s\n' "$arm" "$i" "${ms// /$'\t'}" >>"$results"
    echo "run $i arm=$arm reconnect_ms,first_event_ms=$ms" >&2
  done
done

echo "load average at start: $load_start; at end: $(cut -d" " -f1-3 /proc/loadavg) (1/5/15 min)"
python3 - "$results" "$rtt" "$loss" "$runs" <<'PY'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()]
rtt, loss, runs = sys.argv[2:5]
def pct(v, q):
    v = sorted(v); k = (len(v) - 1) * q; lo = int(k); hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)
print(f"iroh direct, two routes at {rtt} ms RTT / {loss}% loss, route 0 black-holed mid-session; N={runs} per arm; ms from the black hole to the link on route 1")
print(f"{'arm':<34}{'N':>3}{'ok':>4}{'min':>7}{'p50':>7}{'p95':>7}{'max':>7}")
for arm, name in (("after", "warm standby (default)"), ("before", "CMUX_REMOTE_WARM_STANDBY=0")):
    sel = [r for r in rows if r[0] == arm]
    v = [float(r[2]) for r in sel if r[2] != "FAIL" and not r[2].startswith("FAIL")]
    if v:
        print(f"{name:<34}{len(sel):>3}{len(v):>4}{min(v):>7.0f}{pct(v,.5):>7.0f}{pct(v,.95):>7.0f}{max(v):>7.0f}")
    elif sel:
        print(f"{name:<34}{len(sel):>3}{0:>4}")
PY
