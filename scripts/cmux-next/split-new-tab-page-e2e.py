#!/usr/bin/env python3
"""Live check of splits that open the New Tab page (cmuxterm-hq#1829, cx-jfo7) on a running tagged cmux-next build.

A person's Split Right or Down (Cmd-D) from a browser tab, the New Tab page or an agent chat opens
the New Tab page in the new pane, with an Open Tabs list of the workspace's tabs; picking one moves
that tab into the new pane in the page's place. A terminal's split keeps the terminal.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It opens workspaces and tabs with `action.run`, presses
Cmd-D and Cmd-T as a person does (`debug.key`), counts panes and their tabs (`debug.tab_drag`
`strips`), asks whether the focused tab is the New Tab page and reads its Open Tabs rows
(`debug.new_tab` `field`), and clicks a row (`debug.new_tab` `open_tab`). It holds
`tabs.newTabKind` at "page" for Cmd-T and restores it. It never launches or quits the app.

Usage: split-new-tab-page-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
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


def fresh_workspace():
    """A shown workspace with one pane holding one terminal."""
    print("newTab (workspace):", action("newTab", focus=True), flush=True)
    if not wait(lambda: len(strips()) == 1 and len(labels(strips()[0])) == 1, 15):
        sys.exit(f"no single-pane workspace: {json.dumps(strips())[:600]}")
    time.sleep(1)  # test harness: the strip settles


def split():
    """Cmd-D; the strips once there are two panes."""
    print("Cmd-D:", key("d", "command"), flush=True)
    found = wait(lambda: (lambda s: s if len(s) == 2 else None)(strips()), 15)
    time.sleep(1.5)  # test harness: the new pane shows its tab and takes focus
    return found or strips()


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    kind = (rpc("settings.get", {"path": "tabs.newTabKind"}) or {}).get("value")
    print("settings.set tabs.newTabKind page:", rpc("settings.set", {"path": "tabs.newTabKind", "value": "page"}), flush=True)
    try:
        checks()
    finally:
        if kind is None:
            rpc("settings.unset", {"path": "tabs.newTabKind"})
        else:
            rpc("settings.set", {"path": "tabs.newTabKind", "value": kind})


def checks():
    # A terminal's split keeps the terminal.
    fresh_workspace()
    after = split()
    shown = page()
    row("Cmd-D on a terminal splits to a terminal", "two panes; the new one is not the New Tab page",
        f"panes {len(after)}; New Tab page {shown}", len(after) == 2 and shown is None)

    # A browser tab's split opens the New Tab page, listing the workspace's tabs.
    fresh_workspace()
    terminal = labels(strips()[0])[0]
    print("openBrowser:", action("openBrowser", focus=True), flush=True)
    wait(lambda: len(labels(strips()[0])) == 2, 15)
    time.sleep(2)  # test harness: the browser tab loads its title
    source = labels(strips()[0])
    after = split()
    shown = wait(page, 10)
    listed = (shown or {}).get("open_tabs") or []
    row("Cmd-D on a browser tab opens the New Tab page in the new pane, with Open Tabs",
        f"two panes; the focused tab is the New Tab page listing {source}",
        f"panes {[labels(s) for s in after]}; New Tab page {shown}",
        len(after) == 2 and shown is not None and len(listed) >= 2)

    # Picking an Open Tabs row moves that tab into the page's pane, in the page's place.
    index = next((i for i, title in enumerate(listed) if title and (title in terminal or terminal in title)), 0)
    print("open_tab:", rpc("debug.new_tab", {"action": "open_tab", "index": index}), flush=True)
    moved = wait(lambda: (lambda s: s if len(s) == 2 and all(len(labels(x)) == 1 for x in s) and page() is None else None)(strips()), 10)
    final = [labels(s) for s in strips()]
    row("Open Tabs moves the picked tab into the new pane and closes the page",
        "two panes of one tab each; the moved terminal shown; no New Tab page",
        f"picked {listed[index] if index < len(listed) else None}; panes {final}; New Tab page {page()}",
        bool(moved) and shown is not None)

    # The New Tab page's own split opens another New Tab page.
    fresh_workspace()
    print("Cmd-T:", key("t", "command"), flush=True)
    opened = wait(page, 10)
    after = split()
    shown = wait(page, 10)
    row("Cmd-D on the New Tab page opens the New Tab page in the new pane",
        "Cmd-T showed the page; two panes; the new one is the New Tab page",
        f"Cmd-T page {opened is not None}; panes {[labels(s) for s in after]}; New Tab page {shown}",
        opened is not None and len(after) == 2 and shown is not None and bool(shown.get("open_tabs")))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "split-new-tab-page.png")})

    # An agent chat's split opens the New Tab page too (in the chat dock's strip: the dock never splits).
    fresh_workspace()
    print("palette.newAgentChat:", action("palette.newAgentChat", focus=True), flush=True)
    chat = wait(lambda: (lambda r: r if "error" not in r and r.get("text") is None else None)(rpc("debug.new_tab", {"action": "field"}) or {}), 15)
    before = sum(len(labels(s)) for s in strips())
    print("Cmd-D:", key("d", "command"), flush=True)
    shown = wait(page, 15)
    row("Cmd-D on an agent chat opens the New Tab page", "the chat focused; then the focused tab is the New Tab page",
        f"chat {chat}; tabs {before} -> {sum(len(labels(s)) for s in strips())}; New Tab page {shown}",
        chat is not None and shown is not None)


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
