#!/usr/bin/env python3
"""Live check of hint mode on first-party web pages (cx-zjtn.3) on a running tagged cmux-next DEBUG build.

Hint mode (Cmd-J F, a preview feature) labels the window's native controls from the
accessibility tree, which cannot see into web views. First-party pages (New Tab, agent chat,
Settings) are asked through the link hint script, so their buttons get labels too, next to the
native ones. This script opens the New Tab page from a browser tab's split (its Open Tabs list
shows the workspace's tabs), starts hint mode, and types the label of the terminal's Open Tabs
row: the terminal moves into the page's pane, as a click on that row does.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It sets `labs.previewFeatures` and `tabs.newTabKind`
with `settings.set` (and restores them), opens tabs with `action.run`, presses keys as a person
does (`debug.key`), reads the labels (`debug.hints`), the strips (`debug.tab_drag`) and the page
(`debug.new_tab` `field`). It never launches or quits the app.

Usage: web-hints-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
SETTINGS = {"labs.previewFeatures": True, "tabs.newTabKind": "page"}


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


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def action(name):
    return json.dumps(rpc("action.run", {"action": name, "args": {}, "focus": True}))[:160]


def key(name, *modifiers):
    reply = rpc("debug.key", {"key": name, "modifiers": list(modifiers)})
    print("key", "+".join([*modifiers, name]), json.dumps(reply)[:120], flush=True)


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
    return None if "error" in reply or reply.get("text") is None else reply


def hints():
    reply = rpc("debug.hints") or {}
    return reply if "error" not in reply else {"active": False, "hints": [], "error": reply.get("error")}


def new_tab_page():
    """A workspace whose split shows the New Tab page, listing a terminal and a browser tab."""
    print("newTab (workspace):", action("newTab"), flush=True)
    if not wait(lambda: len(strips()) == 1 and len(labels(strips()[0])) == 1, 15):
        sys.exit(f"no single-pane workspace: {json.dumps(strips())[:600]}")
    time.sleep(1)  # test harness: the strip settles
    terminal = labels(strips()[0])[0]
    print("openBrowser:", action("openBrowser"), flush=True)
    wait(lambda: len(labels(strips()[0])) == 2, 15)
    time.sleep(2)  # test harness: the browser tab loads its title
    key("d", "command")
    wait(lambda: len(strips()) == 2, 15)
    shown = wait(lambda: (lambda p: p if p and p.get("open_tabs") else None)(page()), 10)
    time.sleep(1)  # test harness: the page lays out its rows
    return terminal, shown


def checks():
    terminal, shown = new_tab_page()
    listed = (shown or {}).get("open_tabs") or []
    print("terminal:", terminal, "listed:", listed, flush=True)

    key("j", "command")
    key("f")
    labelled = wait(lambda: (lambda h: h if h.get("active") and h.get("hints") else None)(hints()), 5) or hints()
    all_hints = labelled.get("hints") or []
    web = [h for h in all_hints if h.get("role") == "web"]
    native = [h for h in all_hints if h.get("role") != "web"]
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "web-hints.png")})
    target = next((h for h in web if terminal and h.get("title") and (terminal in h["title"] or h["title"] in terminal)), None)
    row("Hint mode labels the New Tab page's buttons next to the native controls",
        f"web labels including the Open Tabs row for {terminal!r}; native labels too",
        f"{len(web)} web {[(h.get('label'), h.get('title')) for h in web][:8]}; {len(native)} native",
        len(web) >= 2 and len(native) >= 5 and target is not None)

    # Typing the row's label clicks it: the terminal moves into the page's pane and the page closes.
    if target:
        for letter in target["label"]:
            key(letter)
    moved = wait(lambda: (lambda s: s if len(s) == 2 and all(len(labels(x)) == 1 for x in s) and page() is None else None)(strips()), 10)
    row("Typing an Open Tabs row's label moves that tab into the page's pane",
        "two panes of one tab each; no New Tab page; hint mode ended",
        f"label {target and target.get('label')}; panes {[labels(s) for s in strips()]}; page {page() is not None}; active {hints().get('active')}",
        bool(target) and bool(moved) and not hints().get("active"))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    before = {path: (rpc("settings.get", {"path": path}) or {}).get("value") for path in SETTINGS}
    try:
        for path, value in SETTINGS.items():
            rpc("settings.set", {"path": path, "value": value})
        time.sleep(0.5)  # test harness: the settings snapshot reloads
        checks()
    finally:
        for path, value in before.items():
            if value is None:
                rpc("settings.unset", {"path": path})
            else:
                rpc("settings.set", {"path": path, "value": value})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
