#!/usr/bin/env python3
"""Cmd-T typeahead on a tagged cmux-next DEBUG app (cx-9fl), through the real key path.

Usage: new-tab-typeahead-proof.py TAG RUNS [TEXT] [MAX_DELAY_MS]   (run on the GUI host; the app must run
with its control socket at /tmp/cmux-debug-TAG.sock; launch it fresh so run 0 is the first
Cmd-T after launch, the cold path)

Each run sends Cmd-T through `debug.key`, waits a random 0..MAX_DELAY_MS (default 0: none),
then sends TEXT (default `hello`) one key at a time as separate socket calls, with no wait for
the page; then reads the New Tab field
(`debug.new_tab {"action": "field"}`) once it settles, and closes the page's tab. It works in a
workspace of its own (one terminal). A run is ok when the field holds TEXT exactly. Exit 1 when
any run lost or reordered a key.
"""
import json, random, socket, sys, time

TAG, RUNS = sys.argv[1], int(sys.argv[2])
TEXT = sys.argv[3] if len(sys.argv) > 3 else "hello"
MAX_DELAY_MS = int(sys.argv[4]) if len(sys.argv) > 4 else 0
CTL = f"/tmp/cmux-debug-{TAG}.sock"


def rpc(method, params=None, timeout=30):
    c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(CTL)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    return json.loads(buf).get("result")


window = rpc("snapshot.get")["topology"]["windows"][0]["key"]
WS = rpc("action.run", {"action": "workspace.newAtBottom", "focus": True, "wait": True})["created"][0]
time.sleep(1.5)


def tabs():
    w = next(w for w in rpc("snapshot.get")["topology"]["workspaces"] if w["id"] == WS)
    return {t["id"] for sc in w["screens"] for p in sc["panes"] for t in p["tabs"]}


rows = []
for run in range(RUNS):
    before = tabs()
    t0 = time.perf_counter()
    rpc("debug.key", {"key": "t", "modifiers": ["command"], "window": window})
    delay_ms = random.uniform(0, MAX_DELAY_MS)
    time.sleep(delay_ms / 1000)
    for ch in TEXT:
        rpc("debug.key", {"key": ch, "window": window})
    typed_ms = (time.perf_counter() - t0) * 1000
    field, settled = None, None
    deadline = time.perf_counter() + 5
    while time.perf_counter() < deadline:
        field = rpc("debug.new_tab", {"action": "field"})
        text = (field or {}).get("text")
        if text == settled and text is not None:
            break
        settled = text
        time.sleep(0.25)
    row = {"run": run, "delay_ms": round(delay_ms), "typed_ms": round(typed_ms, 1), "field": field, "ok": (field or {}).get("text") == TEXT}
    rows.append(row)
    print(json.dumps(row), flush=True)
    for tab in tabs() - before:
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "wait": True})
    time.sleep(0.8)
print(json.dumps({"summary": {"runs": len(rows), "ok": sum(r["ok"] for r in rows),
                              "lost": [r["run"] for r in rows if not r["ok"]]}}))
sys.exit(0 if all(r["ok"] for r in rows) else 1)
