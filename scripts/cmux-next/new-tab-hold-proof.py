#!/usr/bin/env python3
"""Cmd-T on a shown New Tab page: the key hold and its ends (cx-9fl), on a tagged DEBUG app.

Usage: new-tab-hold-proof.py TAG RUNS   (run on the GUI host; control socket /tmp/cmux-debug-TAG.sock)

In a workspace of its own, a first Cmd-T shows the New Tab page. Each run then alternates:
- answer: Cmd-T again (the shown page is adopted with a fresh token) and type `chrome://e<N>`
  at once; the keys wait for the page's answer and must all reach the field;
- gone: `ignore_next_page_answer`, Cmd-T, type; the keys must stay held (the page "never
  answers"); then `page_gone` (as after a crash or a failed load) must end the hold and put the
  keys into the field.
The field is read through `debug.new_tab {"action": "field"}`. Exit 1 when any run failed.
"""
import json, socket, sys, time

TAG, RUNS = sys.argv[1], int(sys.argv[2])
CTL = f"/tmp/cmux-debug-{TAG}.sock"


def rpc(method, params=None):
    c = socket.socket(socket.AF_UNIX); c.settimeout(30); c.connect(CTL)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 22)
        if not chunk: break
        buf += chunk
    c.close()
    return json.loads(buf).get("result")


def key(name, mods=None):
    rpc("debug.key", {"key": name, "modifiers": mods or [], "window": WINDOW})


def field():
    last = None
    for _ in range(20):
        now = rpc("debug.new_tab", {"action": "field"})
        if now == last: return now
        last = now
        time.sleep(0.25)
    return last


def held():
    return sum(int(v) for v in rpc("debug.creation_hold")["held"].values())


WINDOW = rpc("snapshot.get")["topology"]["windows"][0]["key"]
rpc("action.run", {"action": "workspace.newAtBottom", "focus": True, "wait": True})
time.sleep(1.5)
key("t", ["command"])
time.sleep(2.0)
rows = []
for run in range(RUNS):
    case = "gone" if run % 2 else "answer"
    text = f"chrome://e{run}"
    if case == "gone":
        rpc("debug.creation_hold", {"ignore_next_page_answer": True})
    key("t", ["command"])
    for ch in text:
        key(ch)
    time.sleep(0.6)
    waiting = held()
    if case == "gone":
        rpc("debug.creation_hold", {"page_gone": True})
    got = (field() or {}).get("text")
    ok = got == text and (case == "answer" or waiting == len(text)) and held() == 0
    row = {"run": run, "case": case, "held_before_end": waiting, "field": got, "ok": ok}
    rows.append(row)
    print(json.dumps(row), flush=True)
print(json.dumps({"summary": {c: f"{sum(r['ok'] for r in rows if r['case'] == c)}/{sum(r['case'] == c for r in rows)}"
                              for c in ("answer", "gone")}}))
sys.exit(0 if all(r["ok"] for r in rows) else 1)
