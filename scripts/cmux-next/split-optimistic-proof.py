#!/usr/bin/env python3
"""S3 behavior proof on a tagged DEBUG cmux-next app (run on the GUI host, never the laptop).

Usage: split-optimistic-proof.py TAG RUNS [optimistic|old]   (the app must run: /tmp/cmux-debug-TAG.sock)
Drives Cmd+D through the app's real key path (debug.key) in a fresh local workspace and
measures key -> new pane in the control snapshot. Right after each Cmd+D it types
`echo s3typed<N>` + Return into the new pane (before its shell can be ready) and later reads
the new terminal's screen over the daemon socket (read-screen) to check the keys arrived once,
in order. Prints one JSON line per run and a summary. Each run also records the path Cmd+D
took: the first snapshot of the new pane shows a provisional surface (>= 2^62, the optimistic
path) or a daemon surface (the old path). With a third argument the script exits 1 when any
run took another path or lost keys.
"""
import json, os, socket, subprocess, sys, time

TAG, RUNS = sys.argv[1], int(sys.argv[2])
EXPECT = sys.argv[3] if len(sys.argv) > 3 else None
PROVISIONAL_BASE = 1 << 62


def first_surface(pane):
    tabs = pane.get("tabs") or []
    value = str(tabs[0].get("surface", "")) if tabs else ""
    return int(value) if value.isdigit() else None
CTL = f"/tmp/cmux-debug-{TAG}.sock"


def rpc(method, params=None, path=CTL, timeout=30):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(path)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    return json.loads(buf)


def daemon(cmd, path):
    c = socket.socket(socket.AF_UNIX); c.settimeout(10); c.connect(path)
    c.sendall((json.dumps(dict(cmd, id=1)) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    return json.loads(buf.split(b"\n")[0])


def topology():
    return rpc("snapshot.get")["result"]["topology"]


def workspace(ws):
    return next(w for w in topology()["workspaces"] if w["id"] == ws)


def panes(w):
    return {p["id"]: p for sc in w["screens"] for p in sc["panes"]}


def key(name, window, mods=None):
    return rpc("debug.key", {"key": name, "modifiers": mods or [], "window": window})


def daemon_socket():
    out = subprocess.run(["pgrep", "-fl", f"session cmux-app-{TAG} "], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if "--socket" in parts:
            return parts[parts.index("--socket") + 1]
    raise SystemExit("daemon socket not found:\n" + out)


created = rpc("action.run", {"action": "workspace.newAtBottom", "focus": True, "wait": True})
ws = created["result"]["created"][0]
time.sleep(1.5)
window = topology()["windows"][0]["key"]
sock = daemon_socket()
caps = daemon({"cmd": "identify"}, sock)["data"]["capabilities"]
print("daemon serves split-client-keys-v1:", "split-client-keys-v1" in caps, flush=True)
rows = []
for run in range(RUNS):
    # Split the first pane each run; keep the workspace at two panes.
    w = workspace(ws)
    before = set(panes(w))
    first = sorted(before)[0]
    t0 = time.perf_counter()
    key("d", window, ["command"])
    t_key = time.perf_counter()
    new = None
    path = None
    while time.perf_counter() - t0 < 3:
        seen = panes(workspace(ws))
        now = set(seen)
        if now - before:
            new = (now - before).pop()
            surface0 = first_surface(seen[new])
            path = "optimistic" if surface0 is None or surface0 > PROVISIONAL_BASE else "old"
            break
        time.sleep(0.001)
    t_pane = time.perf_counter()
    marker = f"s3typed{run}"
    for ch in "echo " + marker:
        key(ch, window)
    key("return", window)
    time.sleep(2.0)
    w = workspace(ws)
    tab = panes(w)[new]["tabs"][0] if new else None
    surface = int(tab["surface"]) if tab and str(tab.get("surface", "")).isdigit() else None
    screen = daemon({"cmd": "read-screen", "surface": surface}, sock) if surface else {}
    text = (screen.get("data") or {}).get("text", "")
    lines = [line.strip() for line in text.splitlines()]
    row = {"run": run, "key_ms": round((t_key - t0) * 1000, 1), "key_to_pane_ms": round((t_pane - t0) * 1000, 1) if new else None,
           # The marker's output line appears once: the keys ran once, in order.
           "new_pane": new, "path": path, "typed_once": lines.count(marker) == 1,
           "output_line": marker in lines, "screen_tail": lines[-4:] if lines else []}
    rows.append(row)
    print(json.dumps(row), flush=True)
    if new:
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tab['id']}", "wait": True})
    time.sleep(0.8)
v = sorted(r["key_to_pane_ms"] for r in rows if r["key_to_pane_ms"] is not None)
if v:
    print(json.dumps({"summary": "key_to_pane_ms", "n": len(v), "p50": v[len(v) // 2], "max": v[-1],
                      "typed_ok": sum(r["typed_once"] for r in rows),
                      "paths": {p: sum(r["path"] == p for r in rows) for p in ("optimistic", "old")}}))
if EXPECT:
    wrong_path = [r["run"] for r in rows if r["path"] != EXPECT]
    lost_keys = [r["run"] for r in rows if not r["typed_once"]]
    print(json.dumps({"expect": EXPECT, "wrong_path_runs": wrong_path, "lost_key_runs": lost_keys}))
    sys.exit(1 if wrong_path or lost_keys else 0)
