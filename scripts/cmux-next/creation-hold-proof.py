#!/usr/bin/env python3
"""Lifecycle ends of the key hold of a pending split (cx-wb5.76), on a tagged cmux-next DEBUG app.

Usage: creation-hold-proof.py TAG ROUNDS   (run on the GUI host; the app must run with
CMUX_NEXT_INPUT_JOURNAL=1 and its control socket at /tmp/cmux-debug-TAG.sock)

Each round runs every case once. `debug.creation_hold {"pause": true}` makes the split's
resolution wait, so the case can end the hold another way first; then the keys `echo hN<case>`
+ Return are typed through `debug.key` and must be held (`held` count), and must then run once,
in order, in the expected terminal:
- resolve: release the resolution -> the new pane;
- fail: `fail_next`, release -> the original pane (the split failed);
- workspace: switch to another workspace (`workspace.selectLastUsed`) -> that workspace's terminal;
- window: make a second window key (`debug.window.focus`) -> that window's terminal;
- click: click the original pane (`debug.mouse`) -> the original pane.
The expected terminal's screen is read over the daemon socket. Exit 1 when any run failed.
"""
import json, socket, subprocess, sys, time

TAG, ROUNDS = sys.argv[1], int(sys.argv[2])
CTL = f"/tmp/cmux-debug-{TAG}.sock"
CASES = ["resolve", "fail", "workspace", "window", "click"]


def rpc(method, params=None, timeout=30):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(CTL)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    reply = json.loads(buf)
    if "error" in reply and reply["error"]: raise SystemExit(f"{method}: {reply['error']}")
    return reply.get("result")


def daemon(cmd):
    c = socket.socket(socket.AF_UNIX); c.settimeout(10); c.connect(SOCK)
    c.sendall((json.dumps(dict(cmd, id=1)) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    return json.loads(buf.split(b"\n")[0])


def daemon_socket():
    out = subprocess.run(["pgrep", "-fl", f"session cmux-app-{TAG} "], capture_output=True, text=True).stdout.split()
    return out[out.index("--socket") + 1]


def topology():
    return rpc("snapshot.get")["topology"]


def workspace(ws):
    return next(w for w in topology()["workspaces"] if w["id"] == ws)


def panes(ws):
    return {p["id"]: p for sc in workspace(ws)["screens"] for p in sc["panes"]}


def screen(surface):
    text = ((daemon({"cmd": "read-screen", "surface": int(surface)}).get("data")) or {}).get("text", "")
    return [line.strip() for line in text.splitlines() if line.strip()]


def run_action(action, **extra):
    return rpc("action.run", dict({"action": action, "focus": True, "wait": True}, **extra))


def key(window, name, mods=None):
    rpc("debug.key", {"key": name, "modifiers": mods or [], "window": window})


SOCK = daemon_socket()
windows = rpc("snapshot.get")["topology"]["windows"]
WIN_A = windows[0]["key"]
run_action("newWindow")
time.sleep(1.5)
WIN_B = next(w["key"] for w in topology()["windows"] if w["key"] != WIN_A)
rpc("debug.window.focus", {"window": WIN_A})
WS_B = run_action("workspace.newAtBottom")["created"][0]
time.sleep(1.0)
WS_A = run_action("workspace.newAtBottom")["created"][0]
time.sleep(1.5)


def first_surface(ws):
    pane = sorted(panes(ws).values(), key=lambda p: p["id"])[0]
    return pane["id"], pane["tabs"][0]["surface"]


def window_terminal(window_key):
    win = next(w for w in topology()["windows"] if w["key"] == window_key)
    ws = win.get("workspace") or win.get("selected_workspace")
    return first_surface(ws)[1] if ws else None


rows, n = [], 0
for rnd in range(ROUNDS):
    for case in CASES:
        n += 1
        marker = f"h{n}{case}"
        original_pane, original_surface = first_surface(WS_A)
        before = set(panes(WS_A))
        rpc("debug.creation_hold", {"pause": True, "fail_next": case == "fail"})
        key(WIN_A, "d", ["command"])
        for ch in "echo " + marker:
            key(WIN_A, ch)
        key(WIN_A, "return")
        held = sum(int(v) for v in rpc("debug.creation_hold")["held"].values())
        if case == "workspace":
            run_action("workspace.selectLastUsed")
            expect = first_surface(WS_B)[1]
        elif case == "window":
            rpc("debug.window.focus", {"window": WIN_B})
            expect = window_terminal(WIN_B)
        elif case == "click":
            rpc("debug.mouse", {"window": WIN_A, "pane": original_pane})
            expect = original_surface
        time.sleep(0.3)
        held_after_end = sum(int(v) for v in rpc("debug.creation_hold")["held"].values())
        rpc("debug.creation_hold", {"pause": False})
        time.sleep(2.0)
        if case == "resolve":
            new = set(panes(WS_A)) - before
            expect = panes(WS_A)[new.pop()]["tabs"][0]["surface"] if new else None
        elif case == "fail":
            expect = original_surface
        lines = screen(expect) if expect else []
        row = {"n": n, "case": case, "held": held, "held_after_end": held_after_end,
               "ok": held == len("echo " + marker) + 1 and lines.count(marker) == 1,
               "tail": lines[-3:]}
        rows.append(row)
        print(json.dumps(row), flush=True)
        # Back to a two-pane-free workspace A in window A.
        if case == "workspace":
            run_action("workspace.selectLastUsed")
        if case == "window":
            rpc("debug.window.focus", {"window": WIN_A})
        for pane_id in set(panes(WS_A)) - {original_pane}:
            for tab in panes(WS_A)[pane_id]["tabs"]:
                run_action("closeTab", target=f"tab:{tab['id']}")
        time.sleep(0.8)

summary = {c: sum(r["ok"] for r in rows if r["case"] == c) for c in CASES}
print(json.dumps({"summary": summary, "runs_per_case": ROUNDS}))
sys.exit(0 if all(r["ok"] for r in rows) else 1)
