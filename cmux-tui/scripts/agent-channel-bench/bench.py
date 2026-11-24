#!/usr/bin/env python3
"""Agent-channel scoreboard bench: acpmux peer link cold connect and agent-message latency
between two real daemons in two netns joined by a netem link (netns.sh).  Python stdlib only.

  bench.py cold --carrier ssh|ssh-kept|ws [--rtt 50] [--runs 20]   cold connect: peer_add(wait) -> ready
  bench.py send [--rtt 50] [--runs 20]                              warm link: `acpmux send box/lane-x`
  bench.py channel [--rtt 50] [--runs 20]                           warm link: `acpmux channel open --text --reply`

Env: ACPMUX_BIN (default target/release/acpmux of the cargo target below), ACB_DIR (/tmp/acb).
The "Mac end" is daemon A in netns acb-a, the Linux peer is daemon B in acb-b: both Linux.
"""
import argparse, json, os, socket, statistics, subprocess, sys, time, secrets

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.environ.get("ACB_DIR", "/tmp/acb")
USER = os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip()
BIN = os.environ.get("ACPMUX_BIN", os.path.expanduser("~/.cache/agent-chan-target/release/acpmux"))
FAKE = os.path.abspath(os.path.join(HERE, "../../crates/acpmux/tests/fake_agent.py"))
TOK = secrets.token_hex(32)
PORT = 47811


def nsrun(side, argv, env=None, **kw):
    e = ["env"] + [f"{k}={v}" for k, v in (env or {}).items()]
    return subprocess.Popen(["sudo", "-n", "ip", "netns", "exec", f"acb-{side}", "sudo", "-n", "-u", USER] + e + argv, **kw)


def envfor(side):
    h = f"{D}/h{side}"
    return {"HOME": h, "ACPMUX_HOME": f"{h}/.acpmux", "ACPMUX_SOCKET": f"{h}/s.sock",
            "ACPMUX_LOGIN_ENV": "0", "ACPMUX_SPARE_HARNESS": "0", "ACPMUX_CPU_CLASS": "normal",
            "PATH": f"{h}/bin:/usr/local/bin:/usr/bin:/bin"}


class Rpc:
    def __init__(self, side):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(60)
        self.s.connect(envfor(side)["ACPMUX_SOCKET"]); self.f = self.s.makefile("rwb"); self.n = 0

    def call(self, method, **params):
        self.n += 1
        self.f.write((json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n").encode()); self.f.flush()
        while True:
            v = json.loads(self.f.readline())
            if v.get("id") == self.n:
                return v


def start_daemon(side, config, listen=None):
    e = envfor(side); h = e["HOME"]
    os.makedirs(f"{h}/.acpmux", exist_ok=True); os.makedirs(f"{h}/.ssh", exist_ok=True)
    for d in (D, h, f"{h}/.acpmux", f"{h}/.ssh"): os.chmod(d, 0o700)
    json.dump(config, open(f"{h}/.acpmux/config.json", "w")); os.chmod(f"{h}/.acpmux/config.json", 0o600)
    if side == "a":  # ssh reads the passwd home, not $HOME: a PATH shim points it at the lab's ssh_config
        os.makedirs(f"{h}/bin", exist_ok=True)
        open(f"{h}/bin/ssh", "w").write(f'#!/bin/sh\nexec /usr/bin/ssh -F {D}/ssh_config "$@"\n'); os.chmod(f"{h}/bin/ssh", 0o755)
    try: os.unlink(e["ACPMUX_SOCKET"])
    except FileNotFoundError: pass
    argv = [BIN, "daemon", "run", "--log", "info", "--memory"] + (["--insecure-network-listen"] if side == "b" else [])
    if listen: argv += ["--listen", listen, "--insecure-network-listen"]
    p = nsrun(side, argv, e, stdin=subprocess.DEVNULL, stdout=open(f"{h}/daemon.log", "w"), stderr=subprocess.STDOUT, cwd="/tmp")
    for _ in range(300):
        if os.path.exists(e["ACPMUX_SOCKET"]):
            try: Rpc(side); return p
            except OSError: pass
        time.sleep(0.1)
    raise SystemExit(f"daemon {side} did not start; see {h}/daemon.log")


def cli(side, *args, **kw):
    return subprocess.run(["sudo", "-n", "ip", "netns", "exec", f"acb-{side}", "sudo", "-n", "-u", USER, "env"]
                          + [f"{k}={v}" for k, v in envfor(side).items()] + [BIN, *args], capture_output=True, text=True, **kw)


def stats(name, xs, n_expected=None):
    xs = sorted(xs)
    if not xs: return f"{name}: no samples"
    p = lambda q: xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]
    return f"{name}: N={len(xs)} min={xs[0]:.0f} p50={p(.5):.0f} p95={p(.95):.0f} max={xs[-1]:.0f} ms"


def kill_lab():
    """End the processes inside our own acb-* netns (nothing else), then remove the lab."""
    for ns in ("acb-a", "acb-b"):
        pids = subprocess.run(["sudo", "-n", "ip", "netns", "pids", ns], capture_output=True, text=True).stdout.split()
        pids = [p for p in pids if "sshd" not in open(f"/proc/{p}/cmdline").read()] if pids else []
        if pids: subprocess.run(["sudo", "-n", "kill", *pids], capture_output=True)
    time.sleep(0.5)
    subprocess.run([f"{HERE}/netns.sh", "down"], capture_output=True)


def setup(args):
    kill_lab()
    subprocess.run(["rm", "-rf", f"{D}/ha", f"{D}/hb"])
    subprocess.run([f"{HERE}/netns.sh", "down"], capture_output=True)
    subprocess.run([f"{HERE}/netns.sh", "up", str(args.rtt)], check=True, capture_output=True)
    for s in "ab": subprocess.run(["rm", "-rf", f"{D}/h{s}"]) if False else None
    cfg_b = {"websocket": {"token": TOK, "listen": f"0.0.0.0:{PORT}"}, "harnesses": {"fake": {"argv": ["python3", FAKE]}},
             "defaultHarness": "fake", "permissionPolicy": "approve-all"}
    b = start_daemon("b", cfg_b)
    r = cli("b", "run", "-n", "lane-x", "warm up")
    if r.returncode: raise SystemExit("B session: " + r.stdout + r.stderr)
    a = start_daemon("a", {})
    return a, b


def peer_tokens():
    """B's dashboard token (the daemon rewrites it at start) and its peer token."""
    tok = json.load(open(f"{D}/hb/.acpmux/config.json"))["websocket"]["token"]
    return tok, open(f"{D}/hb/.acpmux/run/peer.token").read().strip()


def cold(args, a):
    rpc = Rpc("a"); ready, fb = [], []
    url = {"ssh": f"ssh://box:{PORT}", "ssh-kept": f"ssh://box:{PORT}", "ws": f"ws://10.77.0.2:{PORT}"}[args.carrier]
    kw = {}
    if args.carrier == "ssh-kept": kw = dict(zip(("token", "peerToken"), peer_tokens()))
    if args.carrier == "ws": kw = {"token": peer_tokens()[0]}
    for i in range(args.runs + 1):
        t0 = time.perf_counter()
        pname = f"box{i}"  # a new name each run: its token cache starts empty (the `ssh` carrier reads the tokens over a login of its own)
        r = rpc.call("_acpmux/peer_add", name=pname, url=url, **kw)  # no wait: poll `peers` every ~3 ms
        pr = {}
        while (time.perf_counter() - t0) < 30:
            peers = rpc.call("_acpmux/peers")["result"]["peers"]; pr = peers[0] if peers else {}
            if pr.get("state") == "connected": break
            time.sleep(0.003)
        dt = (time.perf_counter() - t0) * 1000
        ok = pr.get("state") == "connected"
        if i and ok: ready.append(dt)  # run 0 is a warm-up (page cache, sshd), dropped
        if i and not ok: print("run failed:", pr.get("state"), pr.get("error") or r.get("error"), file=sys.stderr)
        ls = pr.get("linkStats") or {}
        if i and ls.get("firstByteMs") is not None: fb.append(ls["firstByteMs"])
        rpc.call("_acpmux/peer_remove", name=pname); time.sleep(0.4)
    print(f"RTT={args.rtt}ms host={os.uname().sysname} (both ends Linux) carrier={args.carrier}")
    print(stats("cold connect peer_add -> state=connected", ready))
    print(stats("  of which daemon firstByteMs (WS open)", fb))


def capture():
    """tcpdump in acb-a.  tcpdump stamps an A->B packet as it leaves acb-va's netem, i.e. when it
    ARRIVES at B, and a B->A packet as it arrives at A: the stamp is always the receiver's time."""
    p = subprocess.Popen(["sudo", "-n", "ip", "netns", "exec", "acb-a", "tcpdump", "-i", "acb-va", "-n", "-tt", "-l", "-U", "tcp"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    p.lines = []
    import threading
    threading.Thread(target=lambda: p.lines.extend(p.stdout), daemon=True).start()
    time.sleep(1.0)
    return p


def payload_times(cap, src_ip):
    """(epoch, length) of each tcp segment with payload from src_ip."""
    time.sleep(0.5); cap.terminate(); time.sleep(0.5); rows = []
    for l in list(cap.lines):
        if f"IP {src_ip}." in l and " length " in l:
            n = int(l.rsplit(" length ", 1)[1].split()[0])
            if n: rows.append((float(l.split()[0]), n))
    return rows


def send(args, a):
    """Row 2: a message from agent A's daemon to a session on B's daemon over a warm link.
    t_arrive = first payload byte after the send command started that reaches B's NIC (tcpdump);
    t_delivered = the sender daemon's `send --status` says delivered (B accepted it)."""
    rpc = Rpc("a")
    kw = dict(zip(("token", "peerToken"), peer_tokens()))
    rpc.call("_acpmux/peer_add", name="box", url=f"ssh://box:{PORT}", **kw)
    time.sleep(4)  # `wait` answers before the link's session list is read: a send then queues ("host unreachable")
    cap = capture(); marks = []; tout = []
    for i in range(args.runs + 1):
        t0 = time.time()
        r = cli("a", "send", "--no-wait", "box/lane-x", f"bench {i}")
        t1 = time.time()
        if r.returncode: print("send failed:", r.stdout, r.stderr, file=sys.stderr); continue
        did = r.stdout.split("id=")[1].split()[0] if "id=" in r.stdout else ""
        done = None
        while time.time() - t0 < 3:
            st = cli("a", "send", "--status").stdout
            if any(did in l and l.startswith("delivered") for l in st.splitlines()): done = time.time(); break
        marks.append((i, t0, t1, done)); time.sleep(0.6)
    rows = payload_times(cap, "10.77.0.1")
    arr, cli_ms, dlv = [], [], []
    for i, t0, t1, done in marks:
        if not i: continue
        nxt = [t for t, n in rows if t >= t0]
        if nxt: arr.append((nxt[0] - t0) * 1000)
        cli_ms.append((t1 - t0) * 1000)
        if done: dlv.append((done - t0) * 1000)
    print(f"RTT={args.rtt}ms host={os.uname().sysname} (both ends Linux) warm ssh peer link, `acpmux send --no-wait box/lane-x`")
    print(stats("send cmd start -> first byte at B's NIC (one-way + CLI + local daemon)", arr))
    print(stats("send cmd start -> CLI returned (queued locally)", cli_ms))
    print(stats("send cmd start -> status=delivered seen (includes B's ack, 1 RTT, and status poll ~20-40 ms)", dlv))


def channel(args, a):
    """Row "agent channel open to first byte": B listens on `review` and echoes; A opens a channel
    with the first bytes in the open frame (`acpmux channel open box review --text hi --reply`).
    Same warm ssh peer link and same clock as `send`: from the command's start, to the first
    byte at B's NIC (tcpdump) and to the echo printed back by A's CLI."""
    rpc = Rpc("a")
    kw = dict(zip(("token", "peerToken"), peer_tokens()))
    rpc.call("_acpmux/peer_add", name="box", url=f"ssh://box:{PORT}", **kw)
    lis = nsrun("b", [BIN, "channel", "listen", "review", "--echo"], envfor("b"),
                stdout=open(f"{D}/hb/listen.log", "w"), stderr=subprocess.STDOUT, cwd="/tmp")
    time.sleep(4)
    cap = capture(); marks = []
    for i in range(args.runs + 1):
        t0 = time.time()
        r = cli("a", "--json", "channel", "open", "box", "review", "--text", f"hi {i}", "--reply")
        t1 = time.time()
        if r.returncode: print("open failed:", r.stdout, r.stderr, file=sys.stderr); continue
        v = json.loads(r.stdout.strip().splitlines()[-1])
        marks.append((i, t0, t1, v)); time.sleep(0.6)
    lis.terminate()
    rows = payload_times(cap, "10.77.0.1")
    arr, wall, opn, first = [], [], [], []
    for i, t0, t1, v in marks:
        if not i: continue
        nxt = [t for t, n in rows if t >= t0]
        if nxt: arr.append((nxt[0] - t0) * 1000)
        wall.append((t1 - t0) * 1000); opn.append(v["openMs"]); first.append(v["firstReplyMs"])
    print(f"RTT={args.rtt}ms host={os.uname().sysname} (both ends Linux) warm ssh peer link, `acpmux channel open box review --text --reply`")
    print(stats("open cmd start -> first byte at B's NIC (one-way + CLI + local daemon)", arr))
    print(stats("open cmd start -> echo printed, CLI exited (1 RTT + B's listener)", wall))
    print(stats("  CLI's own: open request -> channelId answered", opn))
    print(stats("  CLI's own: open request -> first reply byte", first))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("mode", choices=["cold", "send", "channel", "down"])
    ap.add_argument("--carrier", default="ssh"); ap.add_argument("--rtt", type=int, default=50)
    ap.add_argument("--runs", type=int, default=20); ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    if args.mode == "down": kill_lab(); return
    a, b = setup(args)
    try:
        {"cold": cold, "send": send, "channel": channel}[args.mode](args, a)
    finally:
        if not args.keep:
            kill_lab()


if __name__ == "__main__": main()
