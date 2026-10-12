#!/usr/bin/env python3
"""Page menus show every row in a small window (cx-6k6cg), live on a tagged DEV build.

Like a Mac menu, a page's menu with no room in its window goes past the window's edge (the native
host, WebPopupHost) instead of clipping. The check: the window shrinks to 600x400, a new agent
chat opens (Cmd-I), and its composer's Mode menu (side top, rows with descriptions) opens from the
bottom of the window. Every row must show whole: either in the page, or in the host's panel past
the window's edge, with the panel's frame as tall as its rows and on its screen.

  page-popup-escape-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--out DIR]

Prints a PASS/FAIL row per check and the replies it read. Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--menu", default="Mode", help="the composer menu to open (its label)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=30):
    """One line-JSON request on the app's control socket."""
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
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    rpc("debug.key", {"key": "i", "modifiers": ["command"]})
    ready = wait(lambda: "error" not in (rpc("debug.agent_pane", {"action": "readiness"}) or {"error": 1}), 30)
    time.sleep(2)  # test harness: the new chat's composer mounts
    current = (rpc("debug.window_frame") or {}).get("frame") or {}
    frame = rpc("debug.window_frame", {"frame": [current.get("x", 100), current.get("y", 100), 600, 400]}) or {}
    print("window:", json.dumps(frame), "chat ready:", bool(ready), flush=True)
    window = frame.get("frame") or {}
    row("the window is 600x400", "600x400", f"{window.get('width')}x{window.get('height')}",
        round(window.get("width", 0)) == 600 and round(window.get("height", 0)) == 400)
    time.sleep(1)  # test harness: the page lays out at the new size
    rpc("debug.agent_pane", {"action": "close_menus"})
    reply = rpc("debug.agent_pane", {"action": "open_menu", "label": opts.menu}) or {}
    print("open_menu:", json.dumps(reply), flush=True)
    menu = reply.get("menu") or {}
    rows = menu.get("rows") or 0
    row(f"the {opts.menu} menu opened", "open with rows", json.dumps(menu), bool(reply.get("open")) and rows > 0)
    popups = (rpc("debug.page_popup") or {}).get("popups") or []
    print("page_popup:", json.dumps(popups), flush=True)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "page-popup-escape.png")})
    # At 600x400 the Mode menu fits on neither side of its button: it must go past the window.
    row("the menu went past the window's edge", "escaped", json.dumps(menu), bool(menu.get("escaped")))
    if menu.get("escaped"):
        panel = popups[0] if popups else {}
        row("the escaped menu shows in one panel", "1 panel", len(popups), len(popups) == 1)
        row("the panel draws every row", rows, panel.get("rows"), panel.get("rows") == rows)
        row("no row is clipped", "clipped false", panel.get("clipped"), panel.get("clipped") is False)
        row("the panel is all on its screen", "on_screen true", panel.get("on_screen"), panel.get("on_screen") is True)
    else:
        row("every row shows whole in the page", rows, menu.get("shown_in_page"),
            rows > 0 and menu.get("shown_in_page") == rows)
        row("no panel shows past the window", 0, len(popups), not popups)
    rpc("debug.agent_pane", {"action": "close_menus"})
    closed = wait(lambda: not (rpc("debug.page_popup") or {}).get("popups"), 5)
    row("closing the menu removes the panel", "no panel", "none" if closed else "still shown", bool(closed))
    print(f"{sum(ROWS)}/{len(ROWS)} passed", flush=True)
    sys.exit(0 if all(ROWS) else 1)


main()
