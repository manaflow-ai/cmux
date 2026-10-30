#!/usr/bin/env python3
"""Live check that a New Tab page's key hold always ends (nightly 2026-10-11, "I cannot type into cmux
nightly at all") on a running tagged cmux-next build.

Keys typed right after Cmd-T wait in the app until the New Tab field reports it is ready
(NewTabInputCoordinator). A page that never reported ready held every printable key of its window
for good: no terminal, chat composer or New Tab field took text, and Cmd-T opened nothing. The hold
must end when the page is left, and in any case after its limit, giving the keys in typing order to
whatever has focus.

Checks, through the debug socket as a person's keys (`debug.key`, `debug.new_tab`):
1. Cmd-T then typing in the same main-actor turn: the text lands in the New Tab field and the hold ends.
2. Cmd-T, back to the terminal, then typing, all in one turn (the page is left before it could report
   ready): the hold ends, the text reaches the terminal, and Cmd-T opens a New Tab page again.
It never launches or quits the app.

Usage: newtab-key-hold-e2e.py --socket /tmp/cmux-debug-<tag>.sock
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=30):
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


def action(name, args=None, focus=False):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": focus})


def key(name, *modifiers):
    return rpc("debug.key", {"key": name, "modifiers": list(modifiers)})


def wait(check, seconds, step=0.25):
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


def strips():
    """The first window's visible strips."""
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    return [s for s in (rpc("debug.tab_drag") or {}).get("strips") or [] if first is None or s.get("window") == first]


def labels(strip):
    return [t.get("label") for t in strip.get("tabs") or []]


def page():
    """The focused tab's New Tab page state, or None when the focused tab is not one."""
    reply = rpc("debug.new_tab", {"action": "field"}) or {}
    # An agent chat answers too, with no field (`text` null).
    return None if "error" in reply or reply.get("text") is None else reply


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def holds():
    return (rpc("debug.focus") or {}).get("new_tab_key_holds")


def field():
    reply = rpc("debug.new_tab", {"action": "field"}) or {}
    return None if "error" in reply or reply.get("text") is None else reply


def terminal_text():
    """The focused visible terminal's viewport text, or None when the focused pane is no terminal."""
    for window in (rpc("debug.surfaces", {"text": True}) or {}).get("windows") or []:
        for pane in window.get("panes") or []:
            if pane.get("focused") and pane.get("kind") == "terminal":
                return pane.get("text") or ""
    return None


def fresh_workspace():
    """A shown workspace whose focused pane shows one terminal that draws its prompt."""
    print("newTab (workspace):", action("newTab", focus=True), flush=True)
    if wait(lambda: terminal_text() is not None and terminal_text().strip(), 20) is None:
        sys.exit("no focused terminal in a fresh workspace")


def checks():
    # 1. Typed right after Cmd-T: the field gets the text; the hold ends.
    fresh_workspace()
    opened = rpc("debug.new_tab", {"action": "open_and_type", "text": "hold1"})
    typed = wait(lambda: (lambda f: f if f and f.get("text") == "hold1" else None)(field()), 10)
    ended = wait(lambda: holds() == [], 5)
    row("Keys typed right after Cmd-T reach the New Tab field, and the hold ends",
        "field text hold1; no window holds keys", f"open {opened}; field {field()}; holds {holds()}",
        typed is not None and ended is not None)

    # 2. The page left before it could report ready: the keys go on to the terminal shown.
    fresh_workspace()
    left = rpc("debug.new_tab", {"action": "open_and_leave", "text": "echo hold2left"})
    # Well inside the 2 s hold limit: the left page ends the hold, not the limit.
    started = time.time()
    ended = wait(lambda: holds() == [], 1.0, step=0.05)
    ended_ms = round((time.time() - started) * 1000)
    reached = wait(lambda: (lambda t: t if t and "hold2left" in t else None)(terminal_text()), 10)
    row("A New Tab page left before it was ready gives its keys to the terminal shown",
        "no window holds keys within 1 s (before the 2 s limit); the terminal shows hold2left",
        f"leave {left}; hold ended after {ended_ms} ms: {ended is not None}; terminal has it {reached is not None}",
        ended is not None and reached is not None)
    # Cmd-T works again (a held window opened nothing).
    print("Cmd-T:", key("t", "command"), flush=True)
    shown = wait(field, 10)
    row("Cmd-T opens the New Tab page after a left page", "the focused tab is the New Tab page",
        f"field {shown}; holds {holds()}", shown is not None)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    checks()


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
