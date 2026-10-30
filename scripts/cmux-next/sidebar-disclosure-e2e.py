#!/usr/bin/env python3
"""Live check of the sidebar's one disclosure convention (cx-fo2t) on a running tagged cmux-next build.

Group headers and workspace rows use the same chevron: open points down (`disclosure.expanded`),
collapsed points right (`disclosure.collapsed`), at the same size and in the same place. A
workspace row shows its chevron only on hover or when selected. A group header is a solid
colored chip (cx-qno.22): `fill` reports only a state step on it, which shows on hover and not
when its collapsed group holds the selection; only the selected workspace row paints the
selection fill.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It turns on `sidebar.showWorkspaceTabs` (so workspace
rows have a chevron), makes a two-workspace group, and reads each row's `disclosure` and `fill`
from `debug.sidebar_rows`, hovering with `debug.mouse`. It closes the workspaces it made,
restores the setting and never launches or quits the app.

Usage: sidebar-disclosure-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
opts = parser.parse_args()
ROWS = []
CREATED = []
SETTING = "sidebar.showWorkspaceTabs"
DOWN, RIGHT = "disclosure.expanded", "disclosure.collapsed"


def line_json(path, request, timeout):
    """One line-JSON request and its reply line."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(path)
    conn.sendall((json.dumps(request) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    conn.close()
    return json.loads(buf)


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
    try:
        reply = line_json(opts.socket, {"id": 1, "method": method, "params": params or {}}, timeout)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, focus=False, target=None):
    params = {"action": name, "args": args or {}, "focus": focus}
    if target:
        params["target"] = target
    return rpc("action.run", params)


def daemon_socket():
    if opts.daemon_socket:
        return opts.daemon_socket
    temp = os.environ.get("TMPDIR") or subprocess.run(
        ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    session = os.path.basename(opts.socket).replace("cmux-debug-", "cmux-app-", 1)
    return os.path.join(temp, f"cmux-tui-{os.getuid()}", session)


def workspaces():
    snapshot = line_json(daemon_socket(), {"id": 1, "cmd": "list-workspaces"}, 30)
    return (snapshot.get("data") or {}).get("workspaces") or []


def ids(entry):
    """Every string id the daemon gives a workspace (the sidebar keys rows by one of them)."""
    return {v for k, v in entry.items() if isinstance(v, str) and ("id" in k or k == "key") and v}


def known():
    return set().union(*(ids(w) for w in workspaces()))


def new_workspaces(before):
    return [w for w in workspaces() if not ids(w) & before]


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


def rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0].get("rows") or []) if windows else []


def row_of(entry):
    return next((r for r in rows() if str(r.get("key", "")).startswith("workspace(")
                 and any(i in str(r.get("key")) for i in ids(entry))), None)


def header_of(group):
    return next((r for r in rows() if str(r.get("key", "")).startswith("group(") and group in str(r.get("key"))), None)


def target_of(entry):
    return "workspace:" + next((v for v in sorted(ids(entry)) if v.startswith("ws_")), sorted(ids(entry))[0])


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def disclosure(r):
    return (r or {}).get("disclosure") or {}


def hover(r, find):
    """Hovers the row and fails unless its view reports the pointer over it."""
    frame = r["window_frame"]
    rpc("debug.mouse", {"x": frame["x"] + frame["width"] / 2, "y": frame["y"] + frame["height"] / 2, "action": "hover"})
    if not wait(lambda: (find() or {}).get("hovered"), 5):
        sys.exit(f"the hover did not reach row {r.get('key')}")
    time.sleep(0.6)  # test harness: hover fades in


def leave():
    """Moves the pointer off the sidebar, into the content right of it."""
    right = max((r.get("window_frame") or {}).get("x", 0) + (r.get("window_frame") or {}).get("width", 0) for r in rows())
    y = min((r.get("window_frame") or {}).get("y", 0) for r in rows())
    rpc("debug.mouse", {"x": right + 200, "y": y, "action": "hover"})
    if not wait(lambda: not any(r.get("hovered") for r in rows()), 5):
        sys.exit("a sidebar row still reports a hover after leaving")
    time.sleep(0.6)  # test harness: hover fades out


def select(entry):
    key = str((row_of(entry) or {}).get("key", ""))
    sidebar_id = key[key.find("(") + 1:key.rfind(")")].strip('"') if "(" in key else target_of(entry).split(":", 1)[1]
    action("goToWorkspace", {"workspace": sidebar_id}, focus=True)
    if not wait(lambda: (row_of(entry) or {}).get("selected"), 5):
        sys.exit("could not select a workspace")


def main():
    before = known()
    print("workspace.newAtBottom:", action("workspace.newAtBottom"), flush=True)
    first = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    if not first:
        sys.exit("no workspace opened")
    CREATED.append(first)
    action("workspace.moveToNewGroup", {"name": "disclosure e2e"}, target=target_of(first))
    group = wait(lambda: (row_of(first) or {}).get("group"), 10)
    before = known()
    action("workspace.newBelow", target=target_of(first))
    second = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    CREATED.extend([second] if second else [])
    if not group or not second or not wait(lambda: (row_of(second) or {}).get("group") == group, 10):
        sys.exit(f"no two-workspace group: group {group}, second {second and sorted(ids(second))}")
    select(first)
    if not wait(lambda: disclosure(row_of(first)).get("icon"), 10):
        sys.exit("the workspace row has no chevron with sidebar.showWorkspaceTabs on")
    leave()

    header, member = header_of(group), row_of(first)
    h, m = disclosure(header), disclosure(member)
    row("An open group header points down", f"icon {DOWN}", f"icon {h.get('icon')}", h.get("icon") == DOWN)
    row("An open workspace row points down", f"icon {DOWN}", f"icon {m.get('icon')}", m.get("icon") == DOWN)
    # In list points: a member row's view starts right of its group's line.
    def placed(r, d):
        frame, view = d.get("frame") or {}, (r or {}).get("view_frame") or {}
        return {"x": (view.get("x") or 0) + (frame.get("x") or 0), "width": frame.get("width"), "height": frame.get("height")} if frame and view else {}
    hf, mf = placed(header, h), placed(member, m)
    same = bool(hf) and bool(mf) and all(abs((hf[k] or 0) - (mf[k] or -99)) < 0.5 for k in ("x", "width", "height"))
    row("The header and row chevrons share a size and place", "equal list x, width and height",
        f"header {hf}; row {mf}", same)

    other = row_of(second)
    row("An unhovered, unselected workspace hides its chevron", "disclosure shown false",
        f"disclosure {disclosure(other)}", disclosure(other).get("icon") is not None and disclosure(other).get("shown") is False)
    hover(other, lambda: row_of(second))
    row("A hovered workspace shows its chevron", "disclosure shown true",
        f"disclosure {disclosure(row_of(second))}", disclosure(row_of(second)).get("shown") is True)
    row("The selected workspace shows its chevron and the selection fill", "disclosure shown, fill true",
        f"disclosure {disclosure(row_of(first))}; fill {(row_of(first) or {}).get('fill')}",
        disclosure(row_of(first)).get("shown") is True and (row_of(first) or {}).get("fill") is True)

    hover(header_of(group), lambda: header_of(group))
    row("A hovered group header takes the hover step on its chip", "fill true", f"fill {(header_of(group) or {}).get('fill')}",
        (header_of(group) or {}).get("fill") is True)
    leave()

    print("workspaceGroup.collapse:", action("workspaceGroup.collapse", target="workspace-group:" + group), flush=True)
    collapsed = wait(lambda: (lambda r: r if r and disclosure(r).get("icon") != DOWN else None)(header_of(group)), 5) or header_of(group)
    row("A collapsed group header points right", f"icon {RIGHT}", f"icon {disclosure(collapsed).get('icon')}",
        disclosure(collapsed).get("icon") == RIGHT)
    row("A collapsed group holding the selection paints no fill", "fill false", f"fill {(collapsed or {}).get('fill')}",
        (collapsed or {}).get("fill") is False)
    action("workspaceGroup.expand", target="workspace-group:" + group)


if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
    sys.exit("the app does not answer on " + opts.socket)
saved = rpc("settings.get", {"path": SETTING}) or {}
if "error" in saved:
    sys.exit(f"cannot read {SETTING}: {saved['error']}")
try:
    print(f"set {SETTING}=true:", rpc("settings.set", {"path": SETTING, "value": True}), flush=True)
    time.sleep(1)  # test harness: the config reloads
    main()
finally:
    for entry in CREATED:
        action("closeWorkspace", {"confirm": True}, target=target_of(entry))
    previous = saved.get("value") if isinstance(saved, dict) else None
    if previous is None:
        rpc("settings.unset", {"path": SETTING})
    else:
        rpc("settings.set", {"path": SETTING, "value": previous})
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
