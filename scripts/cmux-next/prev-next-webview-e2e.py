#!/usr/bin/env python3
"""Live check that Previous / Next workspace keys work with focus inside a webview.

Leo 2026-10-12: Cmd-Tab is the macOS app switcher, so the in-app keys must be solid. With the
keyboard in a New Tab page's field (the agent pane's webview) of a one-tab workspace, each of
Ctrl-Cmd-] and Ctrl-Cmd-[ must be taken by `nextSidebarTab` / `prevSidebarTab` and move the
sidebar selection one workspace, wrapping. (Ctrl-Tab and Cmd-Shift-] / [ cycle the focused
pane's tabs: #20116, Lawrence 2026-10-15. Ctrl-PageDown / PageUp have no cmux default and reach
the page: Lawrence 2026-10-20.) The palette must
list both commands with their keys.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket and never launches or quits the app.

Usage: prev-next-webview-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


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
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def workspace_keys():
    """The window's workspace rows by title, in sidebar order (the selection names a row by it)."""
    return [r.get("title") for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]


def shown():
    """The window's selected workspace row."""
    selection = sidebar().get("selection") or []
    keys = workspace_keys()
    return next((s for s in selection if s in keys), None)


def field_focused():
    return (rpc("debug.new_tab", {"action": "field"}) or {}).get("focused") is True


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def press(label, key, modifiers, step):
    keys = workspace_keys()
    before = shown()
    focused = field_focused()
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers}) or {}
    expected = keys[(keys.index(before) + step) % len(keys)] if before in keys else None
    after = wait(lambda: shown() if shown() != before else None, 5)
    action = reply.get("action")
    want = "nextSidebarTab" if step > 0 else "prevSidebarTab"
    row(f"{label} from the New Tab field", f"{want}, one workspace {'down' if step > 0 else 'up'}",
        f"field focused={focused} action={action} handled_by={reply.get('handled_by')} {before} -> {after}",
        focused and before is not None and action == want and after == expected)
    # The keyboard lands in the shown workspace's New Tab field again.
    wait(field_focused, 5)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    while len(workspace_keys()) < 3:
        rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
        if not wait(lambda: len(workspace_keys()) >= 3 or None, 10):
            break
    rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
    if not wait(field_focused, 15):
        sys.exit(f"no focused New Tab field: {rpc('debug.new_tab', {'action': 'field'})}")
    window = sidebar()
    print(f"workspaces: {len(workspace_keys())}, shown {shown()}, selection {window.get('selection')}, "
          f"rows {[r.get('key') for r in (window.get('rows') or [])[:3]]}", flush=True)

    press("Ctrl-Cmd-]", "]", ["ctrl", "cmd"], 1)
    press("Ctrl-Cmd-[", "[", ["ctrl", "cmd"], -1)

    path = os.path.join(opts.out, "palette-entries.json")
    rpc("debug.palette.entries", {"path": path})
    text = open(path).read() if os.path.exists(path) else ""
    for title in ("Next Sidebar Item", "Previous Sidebar Item"):
        row(f"palette lists {title}", "listed", "listed" if title in text else "missing", title in text)

    passed = sum(ROWS)
    print(f"RESULT {passed}/{len(ROWS)}", flush=True)
    return 0 if passed == len(ROWS) else 1


if __name__ == "__main__":
    sys.exit(main())
