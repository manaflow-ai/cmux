#!/usr/bin/env bash
# The stall of a live `cmux remote connect` link when its direct route dies at a network change:
# CMUX_BRAID_FAST_FALLBACK=1 (cmux#56738) against the default, on a real kernel network (two
# network namespaces joined by a veth pair), not virtual time.
#
#   sudo cmux-tui/scripts/remote-fast-fallback-bench.sh [CMUX_TUI_BIN] [RUNS]
#
# BIN defaults to cmux-tui/target/release/cmux-tui; RUNS (per arm) to 5. Environment:
#   ARMS="off on"       arms; `off` is the default, `on` sets CMUX_BRAID_FAST_FALLBACK=1, and
#                       `off-nochange` / `on-nochange` black-hole route 0 with no network change
#                       (the heartbeat's ordinary timeout: the control)
#   WATCH_S=10          how long each trial watches after the change
#   KEEP=1              keep the temp dir and the namespaces after the run
#
# Topology (two namespaces this script creates and removes; nothing else is touched):
#   ffb-c (client) 10.78.0.1  <-- veth -->  ffb-d (daemon) 10.78.0.2 (route 0), 10.78.0.3 (route 1)
# Both routes are ws:// (a direct path). The client is paired over route 0 with route 1 as a hint,
# so route 0 is first and route 1 is the warm standby's. Each trial connects (`--headless`), waits
# for the link to settle on route 0, then at T0 black-holes route 0 (netem loss 100 % on the
# client's egress: writes hang, no RST) and, in the same instant, adds an address to the client's
# interface: the kernel network change the link's netlink watch sees (a Wi-Fi switch, a VPN up).
# The link's own address stays, so the dialer's "address gone" shortcut does not fire: the
# heartbeat's post-change probe window (2 s, or 250 ms with the flag) is what decides.
#
# Per trial, from a tcpdump in the client namespace:
#   leave_ms  T0 -> the first SYN to route 1 (the link gave up on route 0)
#   up_ms     T0 -> the end of the first burst on route 1 (upgrade, Noise, resume, replay: the
#             link is carrying again); the burst ends at the first 150 ms gap
#   on_r1     the client holds an established TCP connection to route 1 at the end
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-$here/../target/release/cmux-tui}
runs=${2:-5}
watch_s=${WATCH_S:-10}
port=47941
[ -x "$bin" ] || { echo "no cmux-tui binary at $bin (build: cargo build --release -p cmux-tui)" >&2; exit 2; }
bin=$(readlink -f "$bin")
work=$(mktemp -d /tmp/ffb.XXXXXX)
chmod 700 "$work"
daemon_pid=""
sess="ffb$$"

cleanup() {
  if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi
  if [ "${KEEP:-0}" = 1 ]; then echo "kept $work and namespaces ffb-c ffb-d" >&2; return; fi
  ip netns del ffb-c 2>/dev/null || true
  ip netns del ffb-d 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

ip netns add ffb-c
ip netns add ffb-d
ip link add ffb-vc type veth peer name ffb-vd
ip link set ffb-vc netns ffb-c
ip link set ffb-vd netns ffb-d
nc_() { ip netns exec ffb-c "$@"; }
nd_() { ip netns exec ffb-d "$@"; }
nc_ ip link set lo up
nd_ ip link set lo up
nc_ ip addr add 10.78.0.1/24 dev ffb-vc
nd_ ip addr add 10.78.0.2/24 dev ffb-vd
nd_ ip addr add 10.78.0.3/24 dev ffb-vd
nc_ ip link set ffb-vc up
nd_ ip link set ffb-vd up
nc_ ping -c1 -W2 10.78.0.3 >/dev/null
# Route 0's band: a netem whose loss this script flips (0 % healthy, 100 % black hole).
nc_ tc qdisc add dev ffb-vc root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
nc_ tc qdisc add dev ffb-vc parent 1:3 handle 30: netem loss 0%
nc_ tc filter add dev ffb-vc parent 1: protocol ip prio 1 u32 match ip dst 10.78.0.2/32 flowid 1:3
route0() { nc_ tc qdisc change dev ffb-vc parent 1:3 handle 30: netem loss "$1"; }

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
r0="ws://10.78.0.2:$port/v1/link"
r1="ws://10.78.0.3:$port/v1/link"
invite=$(nd_ env HOME="$dh" XDG_STATE_HOME="$dh/state" XDG_CONFIG_HOME="$dh/config" \
  "$bin" remote enroll create --session "$sess" --state-dir "$dstate" --device-key "$key" \
  --advertise "$r0" --advertise "$r1" | grep -m1 '^cmux://enroll/')
printf '%s\n' "$invite" >"$work/invite"
chmod 600 "$work/invite"
pair_out=$(nc_ "${cenv[@]}" timeout 60 "$bin" remote connect "$r0" --invite-file "$work/invite" \
  --headless --state-dir "$cstate" 2>"$work/pair.err" | head -1) || true
[ -n "$pair_out" ] || { echo "pairing failed:" >&2; cat "$work/pair.err" >&2; exit 4; }
sleep 1

export BENCH_BIN="$bin" BENCH_CSTATE="$cstate" BENCH_CHOME="$ch" BENCH_PORT="$port" BENCH_WATCH="$watch_s" BENCH_WORK="$work"
trial() { # ARM -> "leave_ms up_ms on_r1 settled" or "FAIL reason"
  route0 0%
  nc_ python3 -I - "$1" <<'PY'
import os, signal, subprocess, sys, time, select
arm = sys.argv[1]
port = os.environ["BENCH_PORT"]
state = os.environ["BENCH_CSTATE"]
env = dict(os.environ, HOME=os.environ["BENCH_CHOME"],
           XDG_STATE_HOME=os.environ["BENCH_CHOME"] + "/state",
           XDG_CONFIG_HOME=os.environ["BENCH_CHOME"] + "/config")
env.pop("CMUX_BRAID_FAST_FALLBACK", None)
if arm.startswith("on"):
    env["CMUX_BRAID_FAST_FALLBACK"] = "1"
change = not arm.endswith("nochange")
# First launch every trial, so route 0 (listed first) is the one the link starts on.
try:
    os.unlink(os.path.join(state, "client", "route-last-good.json"))
except FileNotFoundError:
    pass
err = open(os.path.join(os.environ["BENCH_WORK"], f"client-{arm}-{time.time_ns()}.err"), "w")
p = subprocess.Popen([os.environ["BENCH_BIN"], "remote", "connect", "--headless", "--state-dir", state],
                     env=env, stdout=subprocess.PIPE, stderr=err, start_new_session=True)
def stop():
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
def est(ip):
    out = subprocess.run(["ss", "-tnH", "state", "established", "dst", f"{ip}:{port}"],
                         capture_output=True, text=True).stdout
    return len(out.strip().splitlines())
ready, _, _ = select.select([p.stdout], [], [], 30)
if not ready or not p.stdout.readline().strip():
    stop(); print("FAIL connect"); sys.exit()
# Settle: on route 0 only, and long enough for the warm standby to arm.
settled = 0
for _ in range(60):
    if est("10.78.0.2") >= 1 and est("10.78.0.3") == 0:
        settled = 1
        break
    time.sleep(0.1)
time.sleep(3)
if est("10.78.0.2") == 0 or est("10.78.0.3") > 0:
    settled = 0
cap = subprocess.Popen(["tcpdump", "-i", "any", "-tt", "-n", "-l", "-Q", "inout", "tcp", "port", port],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
time.sleep(0.5)
t0 = time.time()
subprocess.run(["tc", "qdisc", "change", "dev", "ffb-vc", "parent", "1:3", "handle", "30:", "netem", "loss", "100%"], check=True)
if change:
    subprocess.run(["ip", "addr", "add", "10.78.0.9/24", "dev", "ffb-vc"], check=True)
time.sleep(float(os.environ["BENCH_WATCH"]))
on_r1 = 1 if est("10.78.0.3") >= 1 else 0
cap.terminate()
out = cap.stdout.read()
stop()
if change:
    subprocess.run(["ip", "addr", "del", "10.78.0.9/24", "dev", "ffb-vc"], check=False)
leave = None
burst = []
for line in out.splitlines():
    f = line.split()
    if len(f) < 5 or "10.78.0.3" not in line:
        continue
    ts = float(f[0])
    if ts < t0:
        continue
    if leave is None:
        if "Flags [S]," in line:
            leave = ts
            burst.append(ts)
        continue
    if ts - burst[-1] > 0.15:
        break
    burst.append(ts)
if leave is None:
    print(f"- - {on_r1} {settled}")
else:
    print(f"{(leave - t0) * 1000:.0f} {(burst[-1] - t0) * 1000:.0f} {on_r1} {settled}")
PY
}

load_start=$(cut -d" " -f1-3 /proc/loadavg)
results="$work/results.tsv"
: >"$results"
read -ra order <<<"${ARMS:-off on}"
for i in $(seq 1 "$runs"); do
  for ((k=0; k<${#order[@]}; k++)); do
    arm=${order[$(( (k + i) % ${#order[@]} ))]}
    r=$(trial "$arm")
    printf '%s\t%s\t%s\n' "$arm" "$i" "${r// /$'\t'}" >>"$results"
    echo "run $i arm=$arm leave_ms,up_ms,on_r1,settled=$r" >&2
  done
done
echo "load average at start: $load_start; at end: $(cut -d" " -f1-3 /proc/loadavg) (1/5/15 min)"
python3 -I - "$results" "$runs" <<'PY'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines()]
def pct(v, q):
    v = sorted(v); k = (len(v) - 1) * q; lo = int(k); hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)
print(f"route 0 (direct, ws) black-holed at T0 with a kernel network change; route 1 healthy; N={sys.argv[2]} per arm")
print(f"{'arm':<16}{'N':>3}{'left':>5}{'on r1':>6}{'settled':>8}   leave_ms p50 [min-max]    up_ms p50 [min-max]")
for arm in dict.fromkeys(r[0] for r in rows):
    sel = [r for r in rows if r[0] == arm and r[2] != "FAIL"]
    lv = [float(r[2]) for r in sel if r[2] != "-"]
    up = [float(r[3]) for r in sel if r[3] != "-"]
    r1 = sum(int(r[4]) for r in sel); st = sum(int(r[5]) for r in sel)
    n = len([r for r in rows if r[0] == arm])
    f = lambda v: f"{pct(v,.5):>6.0f} [{min(v):.0f}-{max(v):.0f}]" if v else "     -"
    print(f"{arm:<16}{n:>3}{len(lv):>5}{r1:>6}{st:>8}   {f(lv):<24}  {f(up)}")
PY
