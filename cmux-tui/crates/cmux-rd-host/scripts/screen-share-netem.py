#!/usr/bin/env python3
"""Screen Sharing under netem: the real `cmux-rd serve` host and `cmux-rd bench --link`
viewer, in two network namespaces joined by a veth whose ends carry `tc netem`.

  sudo screen-share-netem.py BIN --rtt MS --loss PCT [--attempts N] [--samples S]
                             [--blip-at S --blip-s S] [--workload marker|motion]
                             [--out FILE.jsonl]

It is the connectivity harness's netem leg (cmuxterm-hq docs/architecture/connectivity-harness)
applied to Mac Screen's own session path: `serve` is the host Mac Screen runs (`CmuxNextMacScreen`),
the device hub's signaling is played by this script the way `hub-session-local.py` does, and the
link is cmux-rd-link over UDP between the namespaces. Only the capture differs: an Xvfb display with
`cmux-rd testapp` drawing the marker, not ScreenCaptureKit.

With --stun-delay-ms D the host and viewer get a STUN server (this script, in the host's
namespace) that answers each binding request after D ms, as the hub ticket's STUN server does
across the internet; D < 0 never answers (a STUN server that is down or blocked).

Each attempt is one fresh session (new keys, new link). Per attempt it records:
  answer_ms       serve started (the viewer's offer reached the host) -> the host's answer is
                  ready (candidates_done), when the app sends it through the hub
  connect_ms      answer handed to the viewer -> host prints {"connected":true}
  first_frame_ms  the viewer's own clock: answer read -> first decoded marker
  offer_to_first_frame_ms  answer_ms + first_frame_ms: the host's part of Connect -> picture
  g2g_ms          key press -> decoded marker, p50/p95 (input to photon)
  frames_per_s, mbit_per_s
  stalls_ms       with --blip-at: 100 % loss both ways for --blip-s seconds, then the time from
                  the first lost key press to the next one that showed
An attempt that does not connect, or ends before its samples, counts as a failed connect.
"""
import argparse, json, os, select, subprocess, sys, time

HOST_NS, VIEW_NS = "rdshare-h", "rdshare-v"
HOST_IP, VIEW_IP = "10.77.0.1", "10.77.0.2"


def sh(cmd, check=True):
    return subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True)


def netem(rtt, loss, extra=""):
    half = rtt / 2
    for ns, dev in ((HOST_NS, "vh"), (VIEW_NS, "vv")):
        sh(f"ip netns exec {ns} tc qdisc replace dev {dev} root netem delay {half}ms "
           f"loss {loss}% {extra} limit 100000")


def setup(args):
    teardown()
    sh(f"ip netns add {HOST_NS}")
    sh(f"ip netns add {VIEW_NS}")
    sh(f"ip link add vh netns {HOST_NS} type veth peer name vv netns {VIEW_NS}")
    for ns, dev, ip in ((HOST_NS, "vh", HOST_IP), (VIEW_NS, "vv", VIEW_IP)):
        sh(f"ip netns exec {ns} ip link set lo up")
        sh(f"ip netns exec {ns} ip addr add {ip}/24 dev {dev}")
        sh(f"ip netns exec {ns} ip link set {dev} mtu 1500 up")
        sh(f"ip netns exec {ns} ethtool -K {dev} gso off tso off gro off", check=False)
    netem(args.rtt, args.loss)
    disp = args.display
    xvfb = subprocess.Popen(["ip", "netns", "exec", HOST_NS, "Xvfb", disp, "-screen", "0",
                             "1920x1080x24", "-nolisten", "tcp"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    app = subprocess.Popen(["ip", "netns", "exec", HOST_NS, args.bin, "testapp", "--display", disp,
                            "--workload", args.workload],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    return [app, xvfb]


STUN_PORT = 3478

STUN_SERVER = r'''
import socket, struct, sys, threading, time
delay = float(sys.argv[2]) / 1000
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[3])))
def answer(req, peer):
    time.sleep(delay)
    ip = struct.unpack("!I", socket.inet_aton(peer[0]))[0] ^ 0x2112A442
    attr = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, peer[1] ^ 0x2112, ip)
    s.sendto(struct.pack("!HHI", 0x0101, len(attr), 0x2112A442) + req[8:20] + attr, peer)
while True:
    req, peer = s.recvfrom(2048)
    if len(req) >= 20 and req[:2] == b"\x00\x01" and delay >= 0:
        threading.Thread(target=answer, args=(req, peer), daemon=True).start()
'''


def stun_server(delay_ms):
    """A STUN binding responder in the host's namespace that answers after `delay_ms`."""
    return subprocess.Popen(["ip", "netns", "exec", HOST_NS, sys.executable, "-I", "-c", STUN_SERVER,
                             HOST_IP, str(delay_ms), str(STUN_PORT)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def teardown():
    for ns in (HOST_NS, VIEW_NS):
        sh(f"ip netns del {ns}", check=False)


def unbuffered(stream):
    """A child's stdout with no read-ahead. select() waits on the descriptor, so a buffered
    readline() that pulled a whole burst in (key, candidates, candidates_done in one write)
    leaves the rest where select() never sees it, and the next wait sits out its timeout."""
    return os.fdopen(os.dup(stream.fileno()), "rb", buffering=0)


def readline(out, deadline):
    while True:
        left = deadline - time.time()
        if left <= 0:
            return None
        r, _, _ = select.select([out], [], [], left)
        if r:
            return out.readline()


def attempt(args, n):
    rec = {"attempt": n, "rtt_ms": args.rtt, "loss_pct": args.loss, "ok": False}
    session = "netem-" + os.urandom(8).hex()
    bench_args = [args.bin, "bench", "--link", "1", "--samples", str(args.samples),
                  "--input", "key"]
    viewer = subprocess.Popen(["ip", "netns", "exec", HOST_NS if args.one_ns else VIEW_NS, *bench_args], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    host = None
    try:
        viewer_out = unbuffered(viewer.stdout)
        line = readline(viewer_out, time.time() + 10)
        viewer_key = json.loads(line)["key"]
        stun = [f"{HOST_IP}:{STUN_PORT}"] if args.stun_delay_ms is not None else []
        t_offer = time.time()
        host = subprocess.Popen(["ip", "netns", "exec", HOST_NS, *args.host_wrap.split(), args.bin, "serve", "--display",
                                 args.display, "--profile", "baseline", *args.serve_arg],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, bufsize=1)
        host.stdin.write(json.dumps({"session": session, "peer_key": viewer_key, "scope": "control",
                                     "stun": stun, "display": args.display,
                                     "viewer": {"user": "viewer", "install": "bench"}}) + "\n")
        host.stdin.flush()
        host_out = unbuffered(host.stdout)
        host_key, cands = None, []
        dl = time.time() + 10
        while True:
            # The answer waits for candidates_done, as the app's does (serve always prints it).
            line = readline(host_out, dl)
            if not line:
                break
            msg = json.loads(line)
            if "key" in msg:
                host_key = msg["key"]
            elif "candidate" in msg:
                cands.append(msg["candidate"])
            elif msg.get("candidates_done"):
                break
        # Only the veth's own candidate: what a LAN pair or a punched path gives.
        rec["host_candidates"] = cands
        cands = [c for c in cands if HOST_IP in c or args.one_ns] or cands
        t0 = time.time()
        rec["answer_ms"] = round((t0 - t_offer) * 1000, 1)
        viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": stun,
                                       "candidates": cands}) + "\n")
        viewer.stdin.flush()
        blip_done = args.blip_at is None
        blip_until = None
        streams = {host_out: "host", viewer_out: "viewer"}
        deadline = t0 + args.timeout
        while streams and time.time() < deadline:
            if not blip_done and "connect_ms" in rec and time.time() - t0 >= args.blip_at:
                netem(args.rtt, 100)
                blip_until = time.time() + args.blip_s
                blip_done = True
                rec["blip_s"] = args.blip_s
            if blip_until and time.time() >= blip_until:
                netem(args.rtt, args.loss)
                blip_until = None
            r, _, _ = select.select(list(streams), [], [], 0.05)
            for s in r:
                line = s.readline()
                if not line:
                    del streams[s]
                    continue
                who = streams[s]
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if who == "viewer" and "candidate" in msg:
                    rec.setdefault("viewer_candidates", []).append(msg["candidate"])
                    host.stdin.write(json.dumps(msg) + "\n")
                    host.stdin.flush()
                elif who == "host" and "candidate" in msg:
                    # Trickled after the answer (reflexive, relay), as the hub relays them.
                    rec.setdefault("host_trickled", []).append(msg["candidate"])
                    viewer.stdin.write(json.dumps(msg) + "\n")
                    viewer.stdin.flush()
                elif who == "host" and msg.get("connected"):
                    rec["connect_ms"] = round((time.time() - t0) * 1000, 1)
                elif who == "host" and "path" in msg:
                    rec.setdefault("paths", []).append(msg["path"])
                elif who == "host" and "ended" in msg:
                    rec["host_ended"] = msg["ended"]
                elif who == "viewer" and "g2g_ms" in msg:
                    rec["report"] = msg
                    streams.pop(viewer_out, None)
            if "report" in rec:
                break
        if blip_until:
            netem(args.rtt, args.loss)
        rep = rec.get("report")
        if rep:
            rec["first_frame_ms"] = rep.get("first_frame_ms")
            if rec["first_frame_ms"] is not None:
                rec["offer_to_first_frame_ms"] = round(rec["answer_ms"] + rec["first_frame_ms"], 1)
            rec["g2g_ms"] = rep.get("g2g_ms")
            rec["lost"] = rep.get("lost")
            rec["stalls_ms"] = rep.get("stalls_ms")
            rec["frames_per_s"] = rep.get("frames_per_s")
            rec["mbit_per_s"] = rep.get("mbit_per_s")
            rec["ended"] = rep.get("ended")
            rec["ok"] = bool(rep.get("g2g_ms")) and "connect_ms" in rec
            rec.pop("report")
        else:
            err = viewer.stderr.read() if viewer.poll() is not None else ""
            rec["error"] = err.strip()[-400:]
            if args.debug and host and host.poll() is not None:
                rec["host_stderr"] = host.stderr.read().strip()[-1500:]
    except Exception as e:  # noqa: BLE001 - a broken attempt is a failed attempt
        rec["error"] = repr(e)
    finally:
        for p in (viewer, host):
            if p and p.poll() is None:
                try:
                    p.stdin.write(json.dumps({"stop": True}) + "\n")
                    p.stdin.flush()
                except Exception:  # noqa: BLE001
                    pass
        for p in (viewer, host):
            if p:
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bin")
    ap.add_argument("--rtt", type=float, default=50)
    ap.add_argument("--loss", type=float, default=0)
    ap.add_argument("--attempts", type=int, default=50)
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--workload", default="marker")
    ap.add_argument("--display", default=":173")
    ap.add_argument("--blip-at", type=float, default=None)
    ap.add_argument("--blip-s", type=float, default=2)
    ap.add_argument("--timeout", type=float, default=90)
    ap.add_argument("--serve-arg", action="append", default=[])
    ap.add_argument("--out")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--one-ns", action="store_true")
    ap.add_argument("--host-wrap", default="")
    ap.add_argument("--stun-delay-ms", type=float, default=None)
    args = ap.parse_args()
    procs = setup(args)
    if args.stun_delay_ms is not None:
        procs.append(stun_server(args.stun_delay_ms))
    out = open(args.out, "a") if args.out else None
    try:
        for n in range(1, args.attempts + 1):
            rec = attempt(args, n)
            line = json.dumps(rec)
            print(line, flush=True)
            if out:
                out.write(line + "\n")
                out.flush()
    finally:
        for p in procs:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        teardown()


if __name__ == "__main__":
    main()
