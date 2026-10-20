#!/usr/bin/env python3
"""Live check of the group editor bubble with real clicks (Lawrence 2026-10-14: "the rename + color things").

A right-click on a sidebar group header, and on a tab group chip, opens the group editor (the name
field, the color dots and the group rows, as Chrome's tab group bubble), not a plain menu. In the
editor, a typed name with Return renames the group, and Escape closes it. Runs against a tagged app
the caller launched, through its debug socket (setup, state) and cua-driver (real right-clicks,
the editor's accessibility tree, typing). Window images (the editor included) come from
$NX_CAPTURE into --out.

Usage: group-editor-live.py --socket /tmp/cmux-debug-<tag>.sock --pid PID [--out DIR] [--cua PATH]
Exit status 0 when every check passes.
"""
import argparse, json, os, re, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
ROWS = []
RUN = int(time.time()) % 100000
GROUP, RENAMED, TAB_GROUP = f"Editor proof {RUN}", f"Renamed {RUN}", f"Tab proof {RUN}"


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


def action(name, args=None, target=None):
    params = {"action": name, "args": args or {}, "focus": True}
    if target:
        params["target"] = target
    return rpc("action.run", params)


def cua(tool, args):
    r = subprocess.run([opts.cua, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"raw": r.stdout[-300:], "err": r.stderr[-300:]}


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


def check(name, expected, observed, ok):
    ROWS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} | {name} | {expected} | {observed}", flush=True)


def shot(name):
    capture = os.environ.get("NX_CAPTURE")
    if not capture:
        return
    try:
        r = subprocess.run(["bash", capture, "shot", "--pid", str(opts.pid), "--with-popups", "--out", os.path.join(opts.out, f"{name}.png")],
                           capture_output=True, text=True, timeout=60)
        if r.returncode:
            print(f"WARN | capture {name} exit {r.returncode}: {r.stderr.strip()[:200]}", flush=True)
    except subprocess.TimeoutExpired:
        print(f"WARN | capture {name} timed out", flush=True)


def rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0].get("rows") or []) if windows else []


def header(group):
    return next((r for r in rows() if str(r.get("key", "")).startswith("group(") and group in str(r.get("key"))), None)




def windows():
    return cua("list_windows", {"pid": opts.pid}).get("windows", [])


def main_window():
    size = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
    return max(windows(), key=size)


def editor_window(main_id):
    """The editor bubble: a window of the app other than the main one, holding a text field."""
    for w in windows():
        if w["window_id"] == main_id:
            continue
        tree = cua("get_window_state", {"pid": opts.pid, "window_id": w["window_id"], "include_screenshot": False}).get("tree_markdown", "")
        if "AXTextField" in tree:
            return w["window_id"], tree
    return None


def right_click_window_point(main, x_pt, y_pt, label):
    """A right-click at window points from the top-left (debug.sidebar_rows' frame space): first a real
    window-server click (cua-driver), then, if no editor opened, the in-app event path (debug.mouse)."""
    state = cua("get_window_state", {"pid": opts.pid, "window_id": main["window_id"], "include_screenshot": False})
    scale = state.get("screenshot_scale") or 1
    reply = cua("right_click", {"pid": opts.pid, "window_id": main["window_id"], "x": round(x_pt * scale), "y": round(y_pt * scale)})
    print(f"{label}: cua right_click at {x_pt:.0f},{y_pt:.0f} pt (scale {scale}): {str(reply)[:200]}", flush=True)
    found = wait(lambda: editor_window(main["window_id"]), 4)
    if found:
        return found, "cua-driver"
    print(f"{label}: windows after the cua click: {[(w.get('window_id'), w.get('title'), w.get('bounds')) for w in windows()]}", flush=True)
    rpc("debug.mouse", {"x": x_pt, "y": y_pt, "action": "click", "button": "right"}, timeout=5)
    found = wait(lambda: editor_window(main["window_id"]), 4)
    return found, ("debug.mouse" if found else None)


def element(tree, role, pattern):
    for line in tree.split("\n"):
        m = re.search(r"\[element_index (\d+)\]", line) or re.search(r"\[(\d+)\]", line)
        if m and role in line and re.search(pattern, line):
            return int(m.group(1))
    return None


def sidebar_group_checks(main):
    action("workspace.newAtBottom")
    time.sleep(1.5)  # test harness: the new row settles
    target = next((r for r in reversed(rows()) if str(r.get("key", "")).startswith("workspace(")), None)
    if not target:
        return check("A workspace to group", "a workspace row", None, False)
    key = str(target["key"])
    action("workspace.moveToNewGroup", {"name": GROUP}, target="workspace:" + key[key.find("(") + 1:key.rfind(")")].strip('"'))
    group = wait(lambda: next((r.get("group") for r in rows() if r.get("key") == key and r.get("group")), None), 10)
    header_row = group and wait(lambda: header(group), 10)
    if not header_row:
        return check("A group to edit", GROUP, [r.get("key") for r in rows()], False)
    header_row_ref = header_row
    f = header_row_ref["window_frame"]
    found, path = right_click_window_point(main, f["x"] + f["width"] * 0.35, f["y"] + f["height"] / 2, "sidebar header")
    shot("sidebar-editor-open")
    check("Right-click on a group header opens the group editor (name field)", "an editor window with a text field",
          f"opened by {path}", bool(found))
    if not found:
        return
    win, tree = found
    dots = [c for c in ("Grey", "Blue", "Red", "Yellow", "Green", "Pink", "Purple", "Cyan", "Orange") if c in tree]
    check("The editor has the color dots", ">= 8 named colors", dots, len(dots) >= 8)
    rows_seen = [t for t in ("New Workspace in Group", "Move Group to New Window", "Close", "Ungroup", "Delete") if t in tree]
    check("The editor has the group rows", "New Workspace in Group … Delete", rows_seen, len(rows_seen) >= 4)
    field = element(tree, "AXTextField", r".")
    if field is not None:
        cua("click", {"pid": opts.pid, "window_id": win, "element_index": field})
    cua("hotkey", {"pid": opts.pid, "window_id": win, "keys": ["cmd", "a"]})
    cua("type_text", {"pid": opts.pid, "window_id": win, "text": RENAMED})
    cua("press_key", {"pid": opts.pid, "window_id": win, "key": "return"})
    time.sleep(1)  # test harness: the rename goes to the daemon
    shot("sidebar-after-rename")
    if wait(lambda: editor_window(main["window_id"]), 1):
        cua("press_key", {"pid": opts.pid, "window_id": win, "key": "escape"})
    closed = wait(lambda: not editor_window(main["window_id"]), 5)
    check("Escape closes the editor", "no editor window", bool(closed), bool(closed))
    f = header(group)["window_frame"]
    again, _ = right_click_window_point(main, f["x"] + f["width"] * 0.35, f["y"] + f["height"] / 2, "sidebar header again")
    check("Return renamed the group (the reopened editor's name field)", RENAMED, bool(again) and RENAMED in again[1], bool(again) and RENAMED in again[1])
    if again:
        cua("press_key", {"pid": opts.pid, "window_id": again[0], "key": "escape"})


def tab_group_checks(main):
    action("newSurface")
    time.sleep(1)  # test harness: the second tab draws
    print("tabGroup.create:", action("tabGroup.create", {"name": TAB_GROUP}), flush=True)
    time.sleep(1.5)  # test harness: the chip draws
    panes = [p for w in ((rpc("debug.pane_chrome") or {}).get("windows") or []) for p in (w.get("panes") or []) if p.get("pill")]
    if not panes:
        return check("A tab strip with a group chip", "a pane with a tab pill", rpc("debug.pane_chrome"), False)
    (sx, sy, sw, sh), (px, py, pw, ph) = panes[0]["strip"], panes[0]["pill"]
    # The chip sits at the strip's start, before its first tab.
    x = (sx + px) / 2 if px - sx > 24 else sx + 16
    found, path = right_click_window_point(main, x, py + ph / 2, "tab chip")
    shot("tab-editor-open")
    check("Right-click on a tab group chip opens the group editor", "an editor window with a text field", f"opened by {path}", bool(found))
    if found:
        cua("press_key", {"pid": opts.pid, "window_id": found[0], "key": "escape"})


if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 90):
    sys.exit("the app does not answer on " + opts.socket)
time.sleep(2)  # test harness: the restored window settles after launch
rpc("debug.window_frame", {"frame": [60, 60, 1300, 820]})
time.sleep(1)  # test harness: the frame applies
main = main_window()
sidebar_group_checks(main)
tab_group_checks(main)
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
