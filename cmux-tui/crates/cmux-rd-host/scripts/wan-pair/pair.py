#!/usr/bin/env python3
"""One cmux.rd link session between this lane VM and a fleet Mac running mac_agent.py, with the
device hub's signaling played here (as hub-session-local.py does on one Mac) and carried over
udprel to the VM's public address. The media is the product's secure link (STUN, WAN direct).

  pair.py l2m|m2l [--mac-source SRC] [--stun H:P] [--out FILE] [--label L] -- [bench flags]

l2m: Linux host here (`cmux-rd serve --display :99`, Xvfb + `testapp`), Mac viewer bench.
m2l: Mac host (`cmux-rd serve [--source SRC]`), Linux viewer bench here.
Env: PAIR_TOKEN, PAIR_PORT (4104), RD_BIN (local cmux-rd).
"""
import argparse, json, os, select, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from udprel import Chan

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["l2m", "m2l"])
ap.add_argument("--mac-source", default="")
ap.add_argument("--serve-arg", action="append", default=[])
ap.add_argument("--stun", action="append", default=[])
ap.add_argument("--display", default=":99")
ap.add_argument("--out", default="")
ap.add_argument("--label", default="")
ap.add_argument("--public-ip", default="136.67.132.155")
ap.add_argument("--fwd-only", action="store_true", help="m2l: give the Mac host only the forwarder's candidate")
ap.add_argument("--fwd", action="store_true",
                help="m2l: carry the link through punchfwd.py (public 4105, local 4106)")
argv = sys.argv[1:]
bench = argv[argv.index("--") + 1:] if "--" in argv else []
argv = argv[: argv.index("--")] if "--" in argv else argv
a = ap.parse_args(argv)
stun = a.stun or ["stun.cloudflare.com:3478"]
local_bin = os.environ.get("RD_BIN", os.path.expanduser("~/ssl3/cmux-rd-linux"))
T0 = time.time()


def log(*m):
    print(f"[{time.time() - T0:7.2f}s]", *m, file=sys.stderr, flush=True)


s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(os.environ.get("PAIR_PORT", "4104"))))
ch = Chan(s, os.environ["PAIR_TOKEN"])
while ch.peer is None and time.time() - T0 < 10:
    time.sleep(0.05)
if ch.peer is None:
    raise SystemExit("no mac agent ping within 10 s")
log("mac agent at", ch.peer, "dropped stale", ch.drain())


def mac_msg(timeout):
    m = ch.recv(timeout)
    if m is None:
        return None
    if "out" in m:
        try:
            return ("out", json.loads(m["out"]))
        except ValueError:
            return ("text", m["out"])
    if "exit" in m:
        return ("exit", m)
    return ("other", m)


def local(argv, env=None):
    return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                            bufsize=1, env=env)


def local_json(p, timeout):
    end = time.time() + timeout
    while True:
        r, _, _ = select.select([p.stdout], [], [], max(0, end - time.time()))
        if not r:
            return None
        line = p.stdout.readline()
        if not line:
            return {"_eof": True}
        try:
            return json.loads(line)
        except ValueError:
            log("local:", line.rstrip())
        if time.time() >= end:
            return None


def is_report(m):
    return isinstance(m, dict) and ("g2g_ms" in m or "fps" in m or "decoded_frames" in m)


session = "p9-" + os.urandom(8).hex()
setup = {"session": session, "scope": "control", "stun": stun,
         "viewer": {"user": "viewer", "install": "bench"}}
report, events, mac_exit = None, [], None

if a.mode == "l2m":
    ch.send({"start": ["bench", "--link", "1", *bench]})
    vkey = None
    while vkey is None:
        m = mac_msg(15)
        if m is None or m[0] == "exit":
            raise SystemExit(f"no viewer key: {m}")
        if m[0] == "out" and "key" in m[1]:
            vkey = m[1]["key"]
    log("viewer key", vkey[:12])
    host = local([local_bin, "serve", "--display", a.display, *a.serve_arg],
                 env=dict(os.environ, DISPLAY=a.display))
    host.stdin.write(json.dumps({**setup, "peer_key": vkey}) + "\n"); host.stdin.flush()
    hkey, cands = None, []
    while True:
        m = local_json(host, 5)
        if m is None or m.get("_eof"):
            break
        if "key" in m:
            hkey = m["key"]
        elif "candidate" in m:
            cands.append(m["candidate"])
        elif m.get("candidates_done"):
            break
        else:
            log("host:", m)
    if a.public_ip and cands and not any(c.startswith("srflx") for c in cands):
        cands.append(f"srflx {a.public_ip}:" + cands[0].rsplit(":", 1)[1])
    log("host candidates", cands)
    ch.send({"in": json.dumps({"session": session, "peer_key": hkey, "stun": stun, "candidates": cands})})
    t_answer = time.time()
    deadline = time.time() + 300
    while time.time() < deadline and report is None and mac_exit is None:
        m = mac_msg(0.05)
        if m:
            if m[0] == "out" and "candidate" in m[1]:
                host.stdin.write(json.dumps(m[1]) + "\n"); host.stdin.flush()
                log("viewer candidate ->host", m[1]["candidate"])
            elif m[0] == "out" and is_report(m[1]):
                report = m[1]
            elif m[0] == "exit":
                mac_exit = m[1]
            else:
                log("viewer:", m[1])
        while select.select([host.stdout], [], [], 0)[0]:
            line = host.stdout.readline()
            if not line:
                break
            try:
                e = json.loads(line)
            except ValueError:
                continue
            e["_t"] = round(time.time() - t_answer, 3)
            events.append(e)
            log("host:", e)
    try:
        host.stdin.write('{"stop":true}\n'); host.stdin.flush()
        host.wait(10)
    except Exception:
        host.kill()
    if mac_exit is None:
        m = mac_msg(5)
        if m and m[0] == "exit":
            mac_exit = m[1]
else:
    viewer = local([local_bin, "bench", "--link", "1", *bench])
    vkey = local_json(viewer, 10)["key"]
    log("viewer key", vkey[:12])
    serve = ["serve", *a.serve_arg]
    if a.mac_source:
        serve += ["--source", a.mac_source]
    ch.send({"start": serve})
    ch.send({"in": json.dumps({**setup, "peer_key": vkey})})
    hkey, cands = None, []
    while True:
        m = mac_msg(15)
        if m is None or m[0] == "exit":
            raise SystemExit(f"host gave no candidates: {m}")
        if m[0] != "out":
            continue
        l = m[1]
        if "key" in l:
            hkey = l["key"]
        elif "candidate" in l:
            cands.append(l["candidate"])
        elif l.get("candidates_done"):
            break
        else:
            log("host:", l); events.append(l)
    log("host candidates", cands)
    fwd = None
    if a.fwd:
        fwd = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "punchfwd.py"), "4105", "4106", "400"])
        time.sleep(0.2)
        cands = cands + ["host 127.0.0.1:4106"]
        sc = {"candidate": f"srflx {a.public_ip}:4105"}
        ch.send({"in": json.dumps(sc)})
        log("fwd candidate ->host", sc["candidate"])
    viewer.stdin.write(json.dumps({"session": session, "peer_key": hkey, "stun": stun,
                                   "candidates": cands}) + "\n"); viewer.stdin.flush()
    t_answer = time.time()
    synth = set()
    deadline = time.time() + 300
    while time.time() < deadline and report is None:
        m = local_json(viewer, 0.05)
        if m:
            if m.get("_eof"):
                log("viewer ended")
                break
            if "candidate" in m and a.fwd_only:
                log("viewer candidate kept back (--fwd-only)", m["candidate"])
            elif "candidate" in m:
                ch.send({"in": json.dumps(m)})
                log("viewer candidate ->host", m["candidate"])
                port = m["candidate"].rsplit(":", 1)[1]
                if a.public_ip and port not in synth:
                    synth.add(port)
                    sc = {"candidate": f"srflx {a.public_ip}:{port}"}
                    ch.send({"in": json.dumps(sc)})
                    log("synth viewer candidate ->host", sc["candidate"])
            elif is_report(m):
                report = m
            else:
                log("viewer:", m)
        while True:
            mm = mac_msg(0)
            if mm is None:
                break
            if mm[0] == "exit":
                mac_exit = mm[1]
            elif mm[0] == "out":
                mm[1]["_t"] = round(time.time() - t_answer, 3)
                events.append(mm[1]); log("host:", mm[1])
    ch.send({"in": json.dumps({"stop": True})})
    try:
        viewer.wait(10)
    except Exception:
        viewer.kill()
    end = time.time() + 8
    while mac_exit is None and time.time() < end:
        mm = mac_msg(1)
        if mm and mm[0] == "exit":
            mac_exit = mm[1]
        elif mm and mm[0] == "out":
            events.append(mm[1])
    if mac_exit is None:
        ch.send({"kill": 1})
    if fwd:
        fwd.terminate(); fwd.wait(5)

result = {"mode": a.mode, "label": a.label, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0)),
          "bench": bench, "mac_source": a.mac_source, "host_events": events, "report": report,
          "mac_exit": mac_exit}
print(json.dumps(result))
if a.out:
    with open(a.out, "a") as f:
        f.write(json.dumps(result) + "\n")
time.sleep(0.5)
sys.exit(0 if report else 1)
