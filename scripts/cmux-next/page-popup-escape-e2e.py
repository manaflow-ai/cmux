#!/usr/bin/env python3
"""Page menus show every row in a small window (cx-6k6cg), live on a tagged DEV build.

Like a Mac menu, a page's menu with no room in its window goes past the window's edge (the native
host, WebPopupHost) instead of clipping. The check: the window shrinks to 600x400, a new agent
chat opens (Cmd-I), and the composer's folder menu (Location) opens. It must go past the window's
edge, with every row in the host's panel, the panel's frame as tall as its rows and on its screen.
The commands list ("/") and the file list ("@query") open the same way with --surface, in a chat
whose agent is running (they list what the agent sent); test/popup-escape.test.ts covers the
commands list in the browser.

The folder menu lists this Mac's projects: the Mac needs a dozen or so, e.g. git repositories
under ~/Projects made before the app starts (the app scans them once at launch):

  for i in $(seq -w 1 14); do git init -q ~/Projects/popup-fixture-$i; done

  page-popup-escape-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--surface Location --surface /] [--out DIR]

The chat runs on the shared page host, so the checks go through its popup ops
(cmux.app.popup.*, PageRouter), in the engine the page host picks for it.

Prints a PASS/FAIL row per check and the replies it read. Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--surface", action="append",
                    help='a composer menu to open, by its label; "/" for the commands list; "@query" for '
                         'the file list (repeatable; default: Location)')
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
opts.surface = opts.surface or ["Location"]
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


def check_surface(label):
    """Opens one surface from the composer and checks every row shows whole."""
    name = ("the commands list" if label.startswith("/") else "the file list" if label.startswith("@")
            else f"the {label} menu")
    rpc("debug.agent_pane", {"action": "close_menus"})
    reply = rpc("debug.agent_pane", {"action": "open_menu", "label": label}) or {}
    print("open_menu:", json.dumps(reply), flush=True)
    menu = reply.get("menu") or {}
    rows = menu.get("rows") or 0
    row(f"{name} opened", "rows", json.dumps(menu), rows > 0)
    popups = (rpc("debug.page_popup") or {}).get("popups") or []
    print("page_popup:", json.dumps(popups), flush=True)
    slug = "commands" if label.startswith("/") else "files" if label.startswith("@") else label.lower().replace(" ", "-")
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"page-popup-escape-{slug}.png")})
    # At 600x400 each surface fits on no side the page may use: it must go past the window.
    row(f"{name} went past the window's edge", "escaped", json.dumps(menu), bool(menu.get("escaped")))
    if menu.get("escaped"):
        panel = popups[0] if popups else {}
        row(f"{name}: one panel", "1 panel", len(popups), len(popups) == 1)
        row(f"{name}: the panel draws every row", rows, panel.get("rows"), panel.get("rows") == rows)
        row(f"{name}: no row is clipped", "clipped false", panel.get("clipped"), panel.get("clipped") is False)
        row(f"{name}: the panel is all on its screen", "on_screen true", panel.get("on_screen"),
            panel.get("on_screen") is True)
    else:
        row(f"{name}: every row shows whole in the page", rows, menu.get("shown_in_page"),
            rows > 0 and menu.get("shown_in_page") == rows)
        row(f"{name}: no panel shows past the window", 0, len(popups), not popups)
    rpc("debug.agent_pane", {"action": "close_menus"})
    closed = wait(lambda: not (rpc("debug.page_popup") or {}).get("popups"), 5)
    row(f"closing {name} removes the panel", "no panel", "none" if closed else "still shown", bool(closed))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    rpc("debug.key", {"key": "i", "modifiers": ["command"]})
    ready = wait(lambda: "error" not in (rpc("debug.agent_pane", {"action": "readiness"}) or {"error": 1}), 30)
    time.sleep(2)  # test harness: the new chat's composer mounts
    x, y = ((rpc("debug.window_frame") or {}).get("frame") or [100, 100])[:2]  # [x, y, width, height]
    frame = rpc("debug.window_frame", {"frame": [x, y, 600, 400]}) or {}
    print("window:", json.dumps(frame), "chat ready:", bool(ready), flush=True)
    size = [round(v) for v in (frame.get("frame") or [0, 0, 0, 0])[2:]]
    row("the window is 600x400", "600x400", "x".join(map(str, size)), size == [600, 400])
    time.sleep(1)  # test harness: the page lays out at the new size
    for surface in opts.surface:
        check_surface(surface)
    print(f"{sum(ROWS)}/{len(ROWS)} passed", flush=True)
    sys.exit(0 if all(ROWS) else 1)


main()
