#!/usr/bin/env python3
"""Live check of the agent pane's native context menu, through a real right-click.

  scripts/cmux-next/agent-pane-menu-live.py --cli <app>/Contents/Resources/bin/cmux --socket <sock> --pid <pid> [--out DIR]

Runs on a capture-slot mini against a tagged build the caller launched (capture-host launch) on
a clean profile, so the seeded chat opens with the composer focused. It right-clicks down the
transcript with cua-driver until a message's menu opens, and reads that menu from the window's
accessibility tree. The menu must hold only the pane's items: macOS adds AutoFill to a menu
opened while a text field has focus, and a chat message has nothing to fill. Then it finds
the empty-space menu the same way and checks it against the right-click contract (POLISH.md):
one zoom trio with short titles, Find in Chat and Theme. Writes
agent-pane-menu-live.json and the last menu's still to --out. Exit 1 on a failed check.
"""
import argparse, json, os, re, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True)
parser.add_argument("--socket", required=True)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--out", default=tempfile.mkdtemp(prefix="agent-pane-menu-live-"))
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

# Items macOS adds to any menu; none belongs in the pane's.
SYSTEM_ITEMS = {"AutoFill"}
# A message's own menu starts with this (AgentPaneContextMenu).
MESSAGE_ITEM = "Copy Message"
# The empty-space menu leads with this (the chat's own menu, ActionMenuContext.agentChat).
EMPTY_ITEM = "Change Background…"
# The right-click contract's empty-space items (POLISH.md): one zoom trio, Find in Chat and Theme.
EMPTY_WANTED = ["Theme", "Zoom In", "Zoom Out", "Actual Size", "Find in Chat…"]
# Rows the empty-space menu must not repeat: the app's Interface Size trio and the chat zoom's long titles.
EMPTY_UNWANTED = ["Increase Interface Size", "Decrease Interface Size", "Reset Interface Size",
                  "Agent Chat: Zoom In", "Agent Chat: Zoom Out", "Agent Chat: Actual Size"]


def call(method, params=None):
    r = subprocess.run([opts.cli, "--json", "--app-socket", opts.socket, "app", "call", method, json.dumps(params or {})],
                       capture_output=True, text=True, timeout=60)
    return r.stdout


def action(name):
    subprocess.run([opts.cli, "--app-socket", opts.socket, "action", "run", name, "--focus"], capture_output=True, timeout=60)


def cua(tool, args):
    r = subprocess.run([opts.cua, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {}


def window():
    windows = cua("list_windows", {"pid": opts.pid}).get("windows", [])
    size = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
    return max(windows, key=size)["window_id"]


def menu_items(state):
    """The open context menu's item titles (the first AXMenu outside the menu bar)."""
    lines = state.get("tree_markdown", "").split("\n")
    for i, line in enumerate(lines):
        if "] AXMenu " in line and "AXMenuBar" not in lines[max(0, i - 1)]:
            depth = len(line) - len(line.lstrip())
            items = []
            for row in lines[i + 1:]:
                indent = len(row) - len(row.lstrip())
                if indent <= depth:
                    break
                match = re.match(r'- (?:\[\d+\] )?AXMenuItem "([^"]*)"', row.strip())
                if indent == depth + 2 and match:
                    items.append(match.group(1))
            return items
    return []


def scan_menu(win, name, want):
    """The first menu holding `want`, right-clicking down two columns of the transcript."""
    state = cua("get_window_state", {"pid": opts.pid, "window_id": win, "include_accessibility_tree": False})
    scale = state.get("screenshot_scale") or 1
    bounds = state.get("window_bounds") or {}
    width, height = bounds.get("width", 0), bounds.get("height", 0)
    for x in (0.3, 0.62):
        for y in range(int(height * 0.12), int(height * 0.8), 24):
            items = right_click_menu(win, name, (round(width * x * scale), round(y * scale)))
            if want in items:
                return items
    return []


def right_click_menu(win, name, point):
    cua("right_click", {"pid": opts.pid, "window_id": win, "x": point[0], "y": point[1], "delivery_mode": "background"})
    time.sleep(1.2)
    cua("get_desktop_state", {"screenshot_out_file": os.path.join(opts.out, f"{name}.png")})
    items = menu_items(cua("get_window_state", {"pid": opts.pid, "window_id": win, "max_elements": 5000}))
    cua("press_key", {"pid": opts.pid, "window_id": win, "key": "escape", "delivery_mode": "background"})
    time.sleep(0.8)
    return items


for _ in range(45):
    if os.path.exists(opts.socket):
        break
    time.sleep(2)
call("debug.motion", {"action": "speed", "value": "fast"})
action("workspace.selectFirst")
call("debug.showcase.seed")
time.sleep(3)
action("workspace.selectLast")
call("debug.window_frame", {"frame": [60, 60, 1360, 860]})
time.sleep(2)
win = window()
report = {"checks": []}
# The seeded chat opens with the composer focused, the state in which macOS adds AutoFill. A click
# would move focus, so the scan finds a message by right-clicking down the transcript column.
items = scan_menu(win, "message-menu", MESSAGE_ITEM)
if not items:
    report["checks"].append({"check": "a message on screen", "ok": False, "detail": "no right-click opened a message menu"})
else:
    extra = sorted(SYSTEM_ITEMS.intersection(items))
    report["checks"].append({"check": "a message's menu holds only the pane's items", "ok": bool(items) and not extra,
                             "detail": {"items": items, "system": extra}})
items = scan_menu(win, "empty-menu", EMPTY_ITEM)
if not items:
    report["checks"].append({"check": "empty space on screen", "ok": False, "detail": "no right-click opened the empty-space menu"})
else:
    missing = [item for item in EMPTY_WANTED if item not in items]
    repeated = [item for item in EMPTY_UNWANTED if item in items]
    report["checks"].append({"check": "the empty-space menu follows the right-click contract", "ok": not missing and not repeated,
                             "detail": {"items": items, "missing": missing, "repeated": repeated}})
with open(os.path.join(opts.out, "agent-pane-menu-live.json"), "w") as f:
    json.dump(report, f, indent=2)
for check in report["checks"]:
    print(("PASS " if check["ok"] else "FAIL ") + check["check"], json.dumps(check["detail"]))
sys.exit(0 if all(c["ok"] for c in report["checks"]) else 1)
