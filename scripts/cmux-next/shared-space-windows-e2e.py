#!/usr/bin/env python3
"""Two windows on one space share its workspaces and terminals.

Lawrence 2026-11-15: "if i make a new window, it makes it as a new space, so technically it's
accessible from my original window. then if i switch to that space from original window, and
view a terminal, that terminal must be shared".

Steps, all through the app's own control socket (a person's keys go through `debug.key`):

  1. New Window (`action.run newWindow`): window B opens on a new space with its own workspace X.
  2. Switch Space (`space.switch`, B's space) in the first window A: A goes to B's space.
  3. Keys typed in B's terminal.

Judged (`debug.windows`, `debug.surfaces {text}`):

  shows-same-workspace   A shows X, the workspace B shows; no workspace was made for A
  listed-as-guest        A lists X as a guest, B still owns it, the registry reports no problem
  one-terminal-two-views A and B each draw a terminal in a window, with the same daemon terminal id
  both-views-live        the typed marker is on screen in both views
  owner-close-hands-over B closes: A keeps showing X, now as its own, and its terminal still draws

Before the fix A got a new workspace of its own in B's space (the registry let one window list a
workspace), so `shows-same-workspace` failed.

Attaches to a running tagged app (never launches or quits it); writes verdict.json to --out.
Usage: shared-space-windows-e2e.py --socket "$NX_APP_SOCKET" --out DIR
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
MARKER = "zqzqzqzq"


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def windows():
    """{window id: its `debug.windows` entry} of the open windows with a controller."""
    report = rpc("debug.windows") or {}
    rows = report.get("windows") or [] if isinstance(report, dict) else []
    return {w["id"]: w for w in rows if w.get("open") and w.get("has_controller")}


def problems():
    report = rpc("debug.windows") or {}
    return report.get("problems") if isinstance(report, dict) else ["no report"]


def terminals(workspace):
    """The terminal panes that draw `workspace`, one list per window that shows it."""
    report = rpc("debug.surfaces", {"text": True}) or {}
    found = []
    for window in report.get("windows") or [] if isinstance(report, dict) else []:
        panes = [p for p in window.get("panes") or [] if p.get("workspace") == workspace and p.get("kind") == "terminal"]
        if panes:
            found.append(panes)
    return found


def drawn(pane):
    surface = pane.get("surface") or {}
    return bool(pane.get("content_in_window")) and bool(surface.get("exists")) and bool(surface.get("in_window")) and not surface.get("hidden")


def text_of(pane):
    return pane.get("text") or ""  # the view's own viewport text (`debug.surfaces {text}`)


checks, notes = {}, {}


def judge(name, passed, note):
    checks[name] = bool(passed)
    notes[name] = note
    print("%s %s: %s" % ("PASS" if passed else "FAIL", name, json.dumps(note)[:700]), flush=True)


def finish():
    verdict = {"checks": checks, "notes": notes, "pass": bool(checks) and all(checks.values())}
    with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
        json.dump(verdict, handle, indent=1)
    print("verdict:", json.dumps({"checks": checks, "pass": verdict["pass"]}), flush=True)
    sys.exit(0 if verdict["pass"] else 1)


before = wait(windows, 90)
if not before:
    sys.exit("no window answered debug.windows")
a = next((i for i, w in sorted(before.items()) if w.get("visible")), sorted(before)[0])  # a window from before New Window
wait(lambda: windows().get(a, {}).get("selected"), 60)
owned_before = {w for entry in windows().values() for w in entry.get("workspaces") or []}

# 1. New Window: B, on a new space, with its own workspace X.
rpc("action.run", {"action": "newWindow", "origin": "script"})
b = wait(lambda: next((i for i, w in windows().items() if i not in before and w.get("selected") and w.get("visible")), None), 60)
if not b:
    judge("new-window", False, {"windows": windows()})
    finish()
x = windows()[b]["selected"]
wait(lambda: any(drawn(p) for panes in terminals(x) for p in panes), 60)
listed_before = {w for entry in windows().values() for w in entry.get("workspaces") or []}

# 2. A switches to B's space, named by its id (not "the next space": a build may start with more than one).
space = windows()[b].get("space")
rpc("debug.window.focus", {"window": a})
switched = rpc("action.run", {"action": "space.switch", "target": "window:%s" % a, "args": {"space": space}, "focus": True, "origin": "script"})
notes["switch"] = {"space": space, "reply": switched}
wait(lambda: windows().get(a, {}).get("selected") == x, 20)
# sleep-ok: a watch window for something that must not happen: a wrong build makes A's new workspace within 2 s
time.sleep(2.0)
state = windows()
listed_after = {w for entry in state.values() for w in entry.get("workspaces") or []}
judge("shows-same-workspace", state.get(a, {}).get("selected") == x and listed_after == listed_before,
      {"a_selected": state.get(a, {}).get("selected"), "b_selected": x, "made": sorted(listed_after - listed_before)})
judge("listed-as-guest", x in (state.get(a, {}).get("guests") or []) and x not in (state.get(b, {}).get("guests") or []) and not problems(),
      {"a_guests": state.get(a, {}).get("guests"), "b_guests": state.get(b, {}).get("guests"), "problems": problems()})

views = wait(lambda: (v := terminals(x)) and len(v) == 2 and all(any(drawn(p) for p in panes) for panes in v) and v, 30) or terminals(x)
ids = sorted({p.get("terminal_id") for panes in views for p in panes if drawn(p)} - {None})
judge("one-terminal-two-views", len(views) == 2 and len(ids) == 1 and all(any(drawn(p) for p in panes) for panes in views),
      {"windows_drawing": len(views), "terminal_ids": ids,
       "panes": [[{k: p.get(k) for k in ("pane", "kind", "phase", "terminal_id", "attach", "link")} for p in panes] for panes in views]})

# 3. Keys in B's terminal reach both views.
rpc("debug.window.focus", {"window": b})
for char in MARKER:
    rpc("debug.key", {"key": char, "modifiers": [], "window": b})
both = wait(lambda: (v := terminals(x)) and len(v) == 2 and all(any(MARKER in text_of(p) for p in panes) for panes in v), 20)
judge("both-views-live", both, {"views_with_marker": sum(any(MARKER in text_of(p) for p in panes) for panes in terminals(x))})

# 4. B closes: A keeps the workspace, as its own.
rpc("debug.key", {"key": "w", "modifiers": ["control", "cmd"], "window": b})
wait(lambda: b not in windows(), 20)
# Until the hand-over built A's own view: A still selects X, and X is no longer a guest there.
state = wait(lambda: (st := windows()) and st.get(a, {}).get("selected") == x and x not in (st.get(a, {}).get("guests") or []) and st, 20) \
    or windows()
views = wait(lambda: (v := terminals(x)) and len(v) == 1 and any(drawn(p) for p in v[0]) and v, 30) or terminals(x)
judge("owner-close-hands-over", b not in state and state.get(a, {}).get("selected") == x and x not in (state.get(a, {}).get("guests") or [])
      and len(views) == 1 and any(drawn(p) and MARKER in text_of(p) for p in views[0]) and not problems(),
      {"b_open": b in state, "a_selected": state.get(a, {}).get("selected"), "a_guests": state.get(a, {}).get("guests"),
       "views": len(views), "problems": problems()})
finish()
