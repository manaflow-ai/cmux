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


def header_of_name(name):
    return next((r for r in rows() if str(r.get("key", "")).startswith("group(") and r.get("title") == name), None)


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


def right_click_window_point(main, x_pt, y_pt):
    """A real right-click at window points from the top-left (debug.sidebar_rows' frame space)."""
    state = cua("get_window_state", {"pid": opts.pid, "window_id": main["window_id"], "include_screenshot": False})
    scale = state.get("screenshot_scale") or 1
    return cua("right_click", {"pid": opts.pid, "window_id": main["window_id"], "x": round(x_pt * scale), "y": round(y_pt * scale)})


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
    header = wait(lambda: header_of_name(GROUP), 10)
    if not header:
        return check("A group to edit", GROUP, [r.get("title") for r in rows()], False)
    f = header["window_frame"]
    right_click_window_point(main, f["x"] + f["width"] * 0.35, f["y"] + f["height"] / 2)
    found = wait(lambda: editor_window(main["window_id"]), 5)
    shot("sidebar-editor-open")
    check("Right-click on a group header opens the group editor (name field)", "an editor window with a text field",
          bool(found), bool(found))
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
    renamed = wait(lambda: header_of_name(RENAMED), 5)
    check("Typing a name and Return renames the group", RENAMED, [r.get("title") for r in rows() if str(r.get("key", "")).startswith("group(")], bool(renamed))
    shot("sidebar-after-rename")
    if wait(lambda: editor_window(main["window_id"]), 1):
        cua("press_key", {"pid": opts.pid, "window_id": win, "key": "escape"})
    header = header_of_name(RENAMED) or header_of_name(GROUP)
    if header:
        f = header["window_frame"]
        right_click_window_point(main, f["x"] + f["width"] * 0.35, f["y"] + f["height"] / 2)
        again = wait(lambda: editor_window(main["window_id"]), 5)
        if again:
            cua("press_key", {"pid": opts.pid, "window_id": again[0], "key": "escape"})
        closed = wait(lambda: not editor_window(main["window_id"]), 5)
        check("Escape closes the editor", "no editor window", bool(again) and bool(closed), bool(again) and bool(closed))


def tab_group_checks(main):
    print("tabGroup.create:", action("tabGroup.create", {"name": TAB_GROUP}), flush=True)
    time.sleep(1.5)  # test harness: the chip draws
    tree = cua("get_window_state", {"pid": opts.pid, "window_id": main["window_id"], "include_screenshot": False})
    scale = tree.get("screenshot_scale") or 1
    chip = next((e for e in tree.get("elements", []) if TAB_GROUP in str(e.get("label", "")) + str(e.get("value", ""))), None)
    if not chip or not chip.get("frame"):
        return check("A tab group chip on screen (accessibility)", TAB_GROUP, "no chip element", False)
    fr = chip["frame"]
    cua("right_click", {"pid": opts.pid, "window_id": main["window_id"], "x": round((fr["x"] + fr["w"] / 2) * scale), "y": round((fr["y"] + fr["h"] / 2) * scale)})
    found = wait(lambda: editor_window(main["window_id"]), 5)
    shot("tab-editor-open")
    check("Right-click on a tab group chip opens the group editor", "an editor window with a text field", bool(found), bool(found))
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
