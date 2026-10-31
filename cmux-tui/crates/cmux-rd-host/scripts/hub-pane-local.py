#!/usr/bin/env python3
"""Runs `cmux-rd serve` and `cmux-rd connect` on this Mac with a stand-in hub, and a stand-in
pane on connect's Unix socket that sends hello and start the way the app's rd transport does
and counts what comes back. Proves the viewer bridge end to end without the app.

  hub-pane-local.py BIN [--stun HOST:PORT] [--seconds 2]
"""
import json, os, select, socket, struct, subprocess, sys, tempfile, time

binary = sys.argv[1]
stun = [sys.argv[sys.argv.index("--stun") + 1]] if "--stun" in sys.argv else []
seconds = float(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 2.0
session = "pane-" + os.urandom(8).hex()
private = tempfile.mkdtemp(prefix="rd-pane-")
os.chmod(private, 0o700)
sock_path = os.path.join(private, "pane.sock")

viewer = subprocess.Popen([binary, "connect"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
viewer_key = json.loads(viewer.stdout.readline())["key"]
host = subprocess.Popen([binary, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
host.stdin.write(json.dumps({"session": session, "peer_key": viewer_key, "scope": "view", "stun": stun,
                             "viewer": {"user": "viewer", "install": "pane"}}) + "\n"); host.stdin.flush()
host_key = json.loads(host.stdout.readline())["key"]
cands, deadline = [], time.time() + 3
while time.time() < deadline and select.select([host.stdout], [], [], deadline - time.time())[0]:
    line = json.loads(host.stdout.readline())
    if "candidate" in line: cands.append(line["candidate"])
    if line.get("candidates_done"): break
viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": stun, "candidates": cands,
                               "socket": sock_path}) + "\n"); viewer.stdin.flush()
while True:
    line = json.loads(viewer.stdout.readline())
    if "candidate" in line:
        host.stdin.write(json.dumps(line) + "\n"); host.stdin.flush()
    if line.get("listening"): break

def frame(ty, payload):
    return bytes([ty]) + struct.pack("<I", len(payload)) + payload
pane = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); pane.connect(sock_path)
hello = {"t": "hello", "user": "ignored", "install": "pane", "class": "user", "interactive": True,
         "udp_port": None, "max_datagram": 1126, "service": "desktop", "caps": []}
pane.sendall(frame(1, json.dumps(hello).encode()) + frame(1, json.dumps({"t": "start", "key": "k1", "mode": "control"}).encode()))
buf, controls, datagrams, end = b"", [], 0, time.time() + seconds + 10
pane.settimeout(0.2)
first_datagram_at = None
while time.time() < end:
    for s in select.select([viewer.stdout, host.stdout], [], [], 0)[0]:
        line = s.readline()
        if line: print(("viewer" if s is viewer.stdout else "host") + ": " + line.rstrip(), file=sys.stderr)
    try:
        chunk = pane.recv(1 << 20)
    except socket.timeout:
        continue
    if not chunk: break
    buf += chunk
    while len(buf) >= 5:
        ty, n = buf[0], struct.unpack("<I", buf[1:5])[0]
        if len(buf) < 5 + n: break
        payload, buf = buf[5:5 + n], buf[5 + n:]
        if ty == 1: controls.append(json.loads(payload))
        elif ty == 2:
            datagrams += 1
            first_datagram_at = first_datagram_at or time.time()
    if first_datagram_at and time.time() - first_datagram_at > seconds: break
types = [c.get("t") for c in controls]
print(json.dumps({"controls": types, "welcome": next((c for c in controls if c.get("t") == "welcome"), None),
                  "datagrams": datagrams}))
pane.close()
for p in (viewer, host):
    try: p.stdin.write(json.dumps({"stop": True}) + "\n"); p.stdin.flush()
    except BrokenPipeError: pass
for p in (viewer, host): p.wait(timeout=10)
ok = "welcome" in types and "started" in types and datagrams > 10
welcome = next((c for c in controls if c.get("t") == "welcome"), {})
sys.exit(0 if ok else 1)
