#!/usr/bin/env python3
"""Live check that restyling the omnibar's placeholder keeps an edit in place (cx-p0fz).

The address bar restyles its placeholder whenever its tokens change: a light/dark switch, a
density change, a theme change. Setting the placeholder while the field editor is up made AppKit
end and restart the edit. Ending it let the window's focus model put the responder back on the
address bar mid-teardown, which began a new edit inside the old one's end; the nesting ran until
the main-thread watchdog stopped the app. A restart that survives still selects the whole text,
so the caret the user had is lost.

The script opens a workspace with a Chromium tab, types into its omnibar without committing, then
switches the app's own appearance (`debug.appearance`, never the system setting) a few times. After
each switch the app must answer, and the omnibar must still be editing the same text with the
caret where it was. It closes the workspace it made, restores the appearance and never launches
or quits the app.

Usage: omnibar-placeholder-edit-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
opts = parser.parse_args()
ROWS = []
CREATED = []
WORD = "cmux placeholder"


def rpc(method, params=None, timeout=20):
    """One request on the app's control socket (line JSON)."""
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


def wait(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def workspaces():
    snap = rpc("snapshot.get") or {}
    topo = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
    return [ws.get("id") for ws in topo.get("workspaces", [])]


def omnibar():
    reply = rpc("debug.omnibar")
    return reply if isinstance(reply, dict) else {"error": "no reply"}


def edit_state(report):
    return {key: report.get(key) for key in ("phase", "has_focus", "field_editor_active", "field_text", "field_selection")}


def main():
    before = set(workspaces())
    rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
    made = wait(lambda: [ws for ws in workspaces() if ws not in before], 15)
    if not made:
        sys.exit("no workspace opened")
    CREATED.append(made[0])
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": "about:blank"}, "focus": True})
    if not wait(lambda: "error" not in omnibar(), 60, 1):
        sys.exit(f"no omnibar answered: {omnibar()}")

    typed = rpc("debug.omnibar_type", {"text": WORD, "commit": False}) or {}
    start = edit_state(omnibar())
    row("typing starts an edit", f"field editor up with {WORD!r}", start,
        bool(typed.get("typed")) and start["field_editor_active"] and start["field_text"] == WORD)
    if not ROWS[-1]:
        return

    for mode in ("dark", "light", "dark", "light"):
        switched = rpc("debug.appearance", {"mode": mode})
        # The switch restyles the field on the main thread; the app answering proves it is not stuck.
        alive = wait(lambda: "error" not in (rpc("debug.windows", timeout=5) or {"error": 1}), 10)
        after = edit_state(omnibar()) if alive else {}
        row(f"switch to {mode} keeps the edit", f"app answers; edit unchanged {start}",
            f"appearance {(switched or {}).get('effective')}; {after or 'app did not answer'}",
            bool(alive) and after == start)
        if not alive:
            return


if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
    sys.exit("the app does not answer on " + opts.socket)
try:
    main()
finally:
    rpc("debug.key", {"key": "escape"})
    rpc("debug.appearance", {"mode": "system"})
    for workspace in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{workspace}"})
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
