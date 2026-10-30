#!/usr/bin/env python3
"""Live check of the keyboard jump keys (cx-zjtn.2) on a running tagged cmux-next DEBUG build.

- Focus Pane 1…9 (Ctrl-Cmd-1..9) focuses the screen's panes in reading order; 9 is the last
  pane and a number past the last pane leaves focus where it is.
- Focus Sidebar (Ctrl-Cmd-E) puts the keyboard in the workspace list, showing a hidden
  sidebar first; Up and Down there switch workspaces.
- In hint mode (Cmd-J F, a preview feature), Shift on a label's last letter right-clicks the
  control, so its context menu opens from the keyboard.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It opens a workspace and splits it (`action.run`),
presses keys as a person does (`debug.key`) and reads focus (`debug.focus`, `snapshot.get`)
and hint mode with its open menu (`debug.hints`). It sets `labs.previewFeatures` for the hint
check and restores it. It never launches or quits the app.

Usage: jump-keys-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
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


def key(name, *modifiers):
    reply = rpc("debug.key", {"key": name, "modifiers": list(modifiers)})
    print("key", "+".join([*modifiers, name]), json.dumps(reply)[:120], flush=True)
    time.sleep(0.4)  # test harness: the key's focus change lands


def action(name):
    return json.dumps(rpc("action.run", {"action": name, "focus": True}))[:160]


def window_focus():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return windows[0]


def focused_pane():
    return window_focus().get("layout_focused_pane")


def responder():
    return (window_focus().get("appkit") or {}).get("classified")


def sidebar_hidden():
    return (window_focus().get("model") or {}).get("sidebar_hidden")


def focused_workspace():
    snap = rpc("snapshot.get") or {}
    topology = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
    return (topology.get("focus") or {}).get("workspace")


def hints():
    reply = rpc("debug.hints") or {}
    return reply if "error" not in reply else {"active": False, "hints": [], "menu": {}, "error": reply.get("error")}


def panes_by_number():
    """Ctrl-Cmd-1..3 and 9, each followed by the pane focus lands on."""
    landed = {}
    for number in ["1", "2", "3", "9"]:
        key(number, "control", "command")
        landed[number] = focused_pane()
    return landed


def pane_checks():
    print("new workspace:", action("workspace.newAtBottom"), flush=True)
    time.sleep(1.5)  # test harness: the workspace shows and its terminal takes focus
    for _ in range(2):
        print("splitRight:", action("splitRight"), flush=True)
        time.sleep(1)  # test harness: the split pane shows
    panes = len(window_focus().get("topology") or [])
    landed = panes_by_number()
    print("landed:", landed, flush=True)
    distinct = len({landed["1"], landed["2"], landed["3"]}) == 3 and None not in landed.values()
    row("Ctrl-Cmd-1, 2, 3 focus the three panes", "three distinct focused panes",
        f"{panes} panes; {landed}", panes == 3 and distinct)
    row("Ctrl-Cmd-9 focuses the last pane", "the pane Ctrl-Cmd-3 focused", f"9 -> {landed['9']}; 3 -> {landed['3']}",
        distinct and landed["9"] == landed["3"])

    key("1", "control", "command")
    print("focusNextPane:", action("focusNextPane"), flush=True)
    time.sleep(0.4)  # test harness: focus lands
    after_next = focused_pane()
    row("Pane 1 then Next Pane is pane 2", "reading order matches Next Pane", f"{after_next} vs {landed['2']}",
        distinct and after_next == landed["2"])

    key("2", "control", "command")
    key("5", "control", "command")
    row("Ctrl-Cmd-5 with three panes keeps focus", f"stays on {landed['2']}", f"{focused_pane()}",
        distinct and focused_pane() == landed["2"])


def sidebar_checks():
    first = focused_workspace()
    print("new workspace:", action("workspace.newAtBottom"), flush=True)
    time.sleep(1.5)  # test harness: the workspace shows and its terminal takes focus
    second = focused_workspace()

    key("e", "control", "command")
    in_list = wait(lambda: responder() == "sidebar", 3)
    row("Ctrl-Cmd-E puts the keyboard in the sidebar", "responder sidebar", f"{responder()}", bool(in_list))
    key("up")
    up = wait(lambda: focused_workspace() == first, 3)
    key("down")
    down = wait(lambda: focused_workspace() == second, 3)
    row("Up and Down in the sidebar switch workspaces", f"{first} then {second}",
        f"up {bool(up)}, down {bool(down)}, focused {focused_workspace()}", bool(in_list and up and down))

    print("toggleSidebar:", action("toggleSidebar"), flush=True)
    hidden = wait(lambda: sidebar_hidden() is True, 3)
    key("e", "control", "command")
    shown = wait(lambda: sidebar_hidden() is False and responder() == "sidebar", 3)
    row("Ctrl-Cmd-E shows a hidden sidebar and focuses it", "hidden, then shown with responder sidebar",
        f"hidden {bool(hidden)}; now hidden {sidebar_hidden()}, responder {responder()}", bool(hidden and shown))


def menu_checks():
    hints()  # starts following menus
    key("j", "command")
    key("f")
    shown = wait(lambda: (lambda h: h if h.get("active") and h.get("hints") else None)(hints()), 5) or hints()
    target = next((h for h in shown.get("hints") or [] if h.get("role") == "AXRow"), None)
    if target:
        *lead, last = target["label"]
        for letter in lead:
            key(letter)
        key(last, "shift")
    opened = wait(lambda: (hints().get("menu") or {}).get("open"), 5)
    menu = hints().get("menu") or {}
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "hint-menu.png")})
    rpc("debug.hints", {"dismiss_menu": True})
    closed = wait(lambda: not (hints().get("menu") or {}).get("open"), 5)
    row("Shift on a row's label opens its context menu", "a menu with items opens; dismiss closes it",
        f"label {target and target.get('label')} ({target and target.get('title')!r}); menu {json.dumps(menu)[:200]}; closed {bool(closed)}",
        bool(target) and bool(opened) and bool(menu.get("items")) and bool(closed))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    before = (rpc("settings.get", {"path": "labs.previewFeatures"}) or {}).get("value")
    try:
        pane_checks()
        sidebar_checks()
        rpc("settings.set", {"path": "labs.previewFeatures", "value": True})
        time.sleep(0.5)  # test harness: the settings snapshot reloads
        menu_checks()
    finally:
        if before is None:
            rpc("settings.unset", {"path": "labs.previewFeatures"})
        else:
            rpc("settings.set", {"path": "labs.previewFeatures", "value": before})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
