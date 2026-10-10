#!/usr/bin/env python3
"""Interleaved typeahead comparison on tagged cmux-next apps (run on the GUI host, cx-wb5.76).

Usage: typeahead-compare.py ROUNDS MODE... -- TAG...
Each round runs every (TAG, MODE) pair once, in a shuffled order. MODE is `split` (Cmd+D) or
`newterm` (New Terminal Tab, Ctrl-`). The apps run with CMUX_NEXT_INPUT_JOURNAL=1. A run is ok
when the marker's output line shows once AND the new view's attach journal got every typed
byte and no other terminal view got any. Right after the new pane or tab shows in the control snapshot, it types
`echo tk<N>` + Return through debug.key, waits 2 s, and reads the new terminal's screen over
the daemon socket. Each row also carries the app's attach journal after a per-run marker.
"""
import json, random, socket, subprocess, sys, time

args = sys.argv[1:]
ROUNDS = int(args[0])
MODES = args[1:args.index("--")]
TAGS = args[args.index("--") + 1:]
if set(MODES) - {"split", "newterm"}:
    raise SystemExit("MODE must be split or newterm")
PROVISIONAL_BASE = 1 << 62


def rpc(tag, method, params=None, timeout=30):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(f"/tmp/cmux-debug-{tag}.sock")
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


def daemon_socket(tag):
    out = subprocess.run(["pgrep", "-fl", f"session cmux-app-{tag} "], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if "--socket" in parts:
            return parts[parts.index("--socket") + 1]
    raise SystemExit(f"daemon socket not found for {tag}")


def workspace(tag, ws):
    return next(w for w in rpc(tag, "snapshot.get")["result"]["topology"]["workspaces"] if w["id"] == ws)


def tabs(w):
    return {t["id"]: (p["id"], t) for sc in w["screens"] for p in sc["panes"] for t in p["tabs"]}


def all_tabs(tag):
    out = {}
    for w in rpc(tag, "snapshot.get")["result"]["topology"]["workspaces"]:
        out.update(tabs(w))
    return out


def key(tag, name, mods=None):
    return rpc(tag, "debug.key", {"key": name, "modifiers": mods or [], "window": APPS[tag]["window"]})


def find_attach(o):
    if isinstance(o, dict):
        if "event" in o and "phase" in o and "surface" in o: return o
        for v in o.values():
            r = find_attach(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = find_attach(v)
            if r: return r
    return None


APPS = {}
for tag in TAGS:
    created = rpc(tag, "action.run", {"action": "workspace.newAtBottom", "focus": True, "wait": True})
    APPS[tag] = {"ws": created["result"]["created"][0]}
time.sleep(1.5)
for tag in TAGS:
    APPS[tag]["window"] = rpc(tag, "snapshot.get")["result"]["topology"]["windows"][0]["key"]
    APPS[tag]["sock"] = daemon_socket(tag)

order = [(t, m) for t in TAGS for m in MODES]
rows, n = [], 0
for rnd in range(ROUNDS):
    random.shuffle(order)
    for tag, mode in order:
        n += 1
        marker = f"tk{n}"
        ws = APPS[tag]["ws"]
        before = all_tabs(tag)
        rpc(tag, "debug.journal", {"marker": marker, "last": 0})
        t0 = time.perf_counter()
        new, first_surface = None, None
        key(tag, "`", ["control"]) if mode == "newterm" else key(tag, "d", ["command"])
        while time.perf_counter() - t0 < 3:
            now = all_tabs(tag)
            added_any = [t for t in now if t not in before]
            added = [t for t in added_any if now[t][1].get("kind") == "terminal"]
            if added:
                new = added[0]
                s = str(now[new][1].get("surface", ""))
                first_surface = int(s) if s.isdigit() else None
                break
            time.sleep(0.001)
        t_show = time.perf_counter()
        for ch in "echo " + marker:
            key(tag, ch)
        key(tag, "return")
        t_typed = time.perf_counter()
        time.sleep(2.0)
        now = all_tabs(tag)
        tab = now[new][1] if new in now else None
        surface = int(tab["surface"]) if tab and str(tab.get("surface", "")).isdigit() else None
        text = ((daemon({"cmd": "read-screen", "surface": surface}, APPS[tag]["sock"]) if surface else {}).get("data") or {}).get("text", "")
        lines = [line.strip() for line in text.splitlines()]
        journal = rpc(tag, "debug.journal", {"last": 400})["result"]["entries"]
        after, seen = [], False
        for e in journal:
            if json.dumps(e).find(f'"{marker}"') >= 0: seen = True; continue
            a = find_attach(e) if seen else None
            if a:
                after.append({k: a.get(k) for k in ("surface", "event", "phase", "bytes", "droppedBytes") if k in a})
        if not (lines.count(marker) == 1):
            row_extra = {"screen": [l for l in lines if l][-8:], "kinds": None}
        else:
            row_extra = {}
        starts = [a["surface"] for a in after if a.get("event") == "start"]
        new_view = starts[0] if starts else None
        row_extra["new_view_bytes"] = sum(a.get("bytes") or 0 for a in after if a.get("event") == "input" and a.get("surface") == new_view)
        row_extra["other_view_bytes"] = sum(a.get("bytes") or 0 for a in after if a.get("event") == "input" and a.get("surface") != new_view)
        row_extra["typed_bytes"] = len("echo " + marker) + 1
        row = {**row_extra, "n": n, "tag": tag, "mode": mode, "show_ms": round((t_show - t0) * 1000, 1),
               "type_ms": round((t_typed - t_show) * 1000, 1), "first_surface_provisional": bool(first_surface and first_surface > PROVISIONAL_BASE),
               "ok": lines.count(marker) == 1 and row_extra["new_view_bytes"] == row_extra["typed_bytes"] and row_extra["other_view_bytes"] == 0, "tail": [l for l in lines if l][-3:], "attach": after}
        rows.append(row)
        print(json.dumps(row), flush=True)
        if tab:
            rpc(tag, "action.run", {"action": "closeTab", "target": f"tab:{tab['id']}", "wait": True})
        time.sleep(0.8)

summary = {}
for r in rows:
    k = f"{r['tag']}/{r['mode']}"
    s = summary.setdefault(k, {"runs": 0, "ok": 0, "lost": [], "bytes_ok": 0})
    s["runs"] += 1; s["ok"] += r["ok"]
    s["bytes_ok"] += r["new_view_bytes"] == r["typed_bytes"] and r["other_view_bytes"] == 0
    if not r["ok"]: s["lost"].append(r["n"])
print(json.dumps({"summary": summary}))
