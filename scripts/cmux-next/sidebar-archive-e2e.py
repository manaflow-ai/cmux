#!/usr/bin/env python3
"""Archiving sidebar items end to end on a no-activate tagged build (plans/cmux-next/archiving-DESIGN.md).

Drives the app only through its debug socket, as the CLI does, and reads what the rows draw
(`debug.sidebar_rows`: order, group, `archived`):

- Archive Workspace on a grouped row moves it to the end of its group and dims it; the right-click
  menu then reads Unarchive Workspace; Unarchive puts it back where it was;
- Archive on an ungrouped row moves it to the end of the list (root) and dims it;
- Archive Group moves the group to the end and dims its header and its members;
- the user's archive (palette) is one undo step: Cmd-Z undoes it;
- the archived marks survive an app restart (the daemon keeps them).

Each check prints PASS or FAIL; the exit code is the number of failed checks. Window snapshots (light
and dark) go to --out. Run on the GUI host inside `nx-remote --needs gui`, never on the laptop.

Usage: sidebar-archive-e2e.py --tag <tag> [--out DIR] [--app PATH]
"""
import argparse, glob, json, os, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app (default: $NX_APP, else the tag's DerivedData build)")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = next(iter(glob.glob(os.path.join(APP, "Contents/MacOS/cmux*"))), os.path.join(APP, "Contents/MacOS/cmux DEV"))
SCRATCH = tempfile.mkdtemp(prefix=f"archive-{opts.tag}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
FAILED = []


def say(line):
    print(line, flush=True)


def check(name, ok, detail=""):
    say(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ""))
    if not ok:
        FAILED.append(name)
    return ok


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
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


def run(action, args=None, target=None):
    params = {"action": action}
    if args:
        params["args"] = args
    if target:
        params["target"] = target
    reply = rpc("action.run", params)
    say(f"  action.run {action}: {json.dumps(reply)[:200]}")
    return reply if isinstance(reply, dict) else {}


def wait(label, predicate, timeout=15):
    """Polls `predicate` until it is truthy (test harness wait, not app code)."""
    deadline = time.time() + timeout
    value = None
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    say(f"  timed out: {label}")
    return value


def key(name, modifiers=(), target=None):
    params = {"key": name, "modifiers": list(modifiers)}
    if target:
        params["target"] = target
    return rpc("debug.key", params)


def topology():
    return ((rpc("snapshot.get") or {}).get("topology")) or {}


def sidebar():
    report = rpc("debug.sidebar_rows") or {}
    windows = report.get("windows") or [{}]
    return windows[0]


def rows():
    return [r for r in sidebar().get("rows", []) if r.get("in_list")]


def row(title):
    return next((r for r in rows() if r.get("title") == title), None)


def group_row(name_key):
    return next((r for r in rows() if (r.get("key") or "").startswith("group(") and name_key in (r.get("key") or "")), None)


def order():
    """The drawn workspace and group rows, top to bottom: titles, groups as `[G]` keys."""
    out = []
    for r in rows():
        if r.get("title"):
            out.append(r["title"])
        elif (r.get("key") or "").startswith("group("):
            out.append("[G]")
    return out


def members(group_id):
    return [r["title"] for r in rows() if r.get("group") == group_id and r.get("title")]


def archived(title):
    found = row(title)
    return bool(found and found.get("archived"))


def menu_at(frame):
    x, y = frame["x"] + min(40, frame["width"] / 2), frame["y"] + frame["height"] / 2
    reply = rpc("debug.sidebar_rows", {"menu_x": x, "menu_y": y}) or {}
    titles = [t for t in (reply.get("menu") or []) if t != "-"]
    for sub in (reply.get("submenus") or {}).values():
        titles += [t for t in sub if t != "-"]
    return titles


def shot(name):
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-{mode}.png")}, timeout=60)


def palette_run(query):
    key("p", ["command", "shift"])
    probe = os.path.join(opts.out, "palette.png")
    if not wait("palette opens", lambda: "error" not in (rpc("debug.palette.capture", {"path": probe}) or {"error": 1}), 5):
        return False
    for ch in query:
        key("space" if ch == " " else ch, target="palette")
    time.sleep(0.5)  # test harness: let the palette filter settle
    key("return", target="palette")
    return True


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720", "CMUX_DEV_BACKEND_MODE": "local", "ACPMUX_AGENT_LAUNCH": "deny"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(opts.out, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    up = wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and topology().get("loaded"), 120)
    check("app launches", bool(up), f"pid {app.pid}")
    check("the sidebar document is active", bool(wait("doc active", lambda: ((rpc("debug.sidebar_rows") or {}).get("doc") or {}).get("active"), 60)))
    return app


def quit_app(app, how):
    action = {"keep-sessions": "quitKeepSessions", "end-sessions": "quitEndSessions"}[how]
    reply = rpc("action.run", {"action": action}, timeout=15)
    say(f"  quit {how}: {json.dumps(reply)[:160]}")
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"  app pid {app.pid} did not quit; SIGKILL that pid")
        app.kill()
        app.wait(timeout=10)


teardown = TagTeardown(APP, log=say)
teardown.install()
app = None
try:
    app = launch()
    ws = {}
    for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo"):
        made = run("newTab", {"name": name})
        ws[name] = (made.get("created") or [None])[0]
    if not check("five named workspaces", bool(wait("rows named", lambda: set(ws) <= set(order()), 30)), json.dumps(order())):
        raise SystemExit("setup failed")
    # A group of Alpha, Beta, Gamma (in that order); Delta and Echo stay ungrouped.
    run("newWorkspaceGroup", {"name": "Proj"}, target={"kind": "workspace", "id": ws["Alpha"]})
    group_id = wait("group made", lambda: (row("Alpha") or {}).get("group"), 15)
    for name in ("Beta", "Gamma"):
        run("moveWorkspaceToGroup", {"group": {"kind": "workspaceGroup", "id": group_id}}, target={"kind": "workspace", "id": ws[name]})
    wait("three members", lambda: len(members(group_id)) == 3, 15)
    run("workspaceGroup.sortByName", target={"kind": "workspaceGroup", "id": group_id})
    before_members = wait("members sorted", lambda: (lambda m: m if m == ["Alpha", "Beta", "Gamma"] else None)(members(group_id)), 10)
    check("group Proj lists Alpha, Beta, Gamma", bool(before_members), json.dumps(members(group_id)))
    before_order = order()
    say(f"  before: {json.dumps(before_order)}")
    shot("1-before")

    # Archive a grouped workspace: end of its group, dimmed, menu flips.
    alpha_menu = menu_at(row("Alpha")["window_frame"])
    check("the row menu offers Archive Workspace", "Archive Workspace" in alpha_menu, json.dumps(alpha_menu))
    run("workspace.toggleArchive", target={"kind": "workspace", "id": ws["Alpha"]})
    moved = wait("Alpha last in group", lambda: (lambda m: m if m == ["Beta", "Gamma", "Alpha"] else None)(members(group_id)), 10)
    check("Archive moves a grouped workspace to the end of its group", bool(moved), json.dumps(members(group_id)))
    check("the archived row draws dimmed", bool(wait("Alpha dimmed", lambda: archived("Alpha"), 5)))
    check("its neighbors stay undimmed", not archived("Beta") and not archived("Gamma"))
    check("it stays in its group", (row("Alpha") or {}).get("group") == group_id)
    alpha_menu = menu_at(row("Alpha")["window_frame"])
    check("the menu now reads Unarchive Workspace", "Unarchive Workspace" in alpha_menu, json.dumps(alpha_menu))

    # Archive an ungrouped workspace: end of the list (root), dimmed.
    run("workspace.toggleArchive", target={"kind": "workspace", "id": ws["Delta"]})
    root_last = wait("Delta last", lambda: (lambda o: o if o and o[-1] == "Delta" else None)(order()), 10)
    check("Archive moves an ungrouped workspace to the end of the list", bool(root_last), json.dumps(order()))
    check("the archived root row draws dimmed", archived("Delta"))
    shot("2-archived")

    # Unarchive restores both places.
    run("workspace.toggleArchive", target={"kind": "workspace", "id": ws["Alpha"]})
    back = wait("Alpha back first", lambda: (lambda m: m if m == ["Alpha", "Beta", "Gamma"] else None)(members(group_id)), 10)
    check("Unarchive puts the grouped workspace back where it was", bool(back), json.dumps(members(group_id)))
    check("the unarchived row is no longer dimmed", not archived("Alpha"))
    run("workspace.toggleArchive", target={"kind": "workspace", "id": ws["Delta"]})
    check("Unarchive puts the root workspace back where it was",
          bool(wait("order restored", lambda: order() == before_order, 10)), json.dumps(order()))

    # Archive the group: last, header and members dimmed.
    run("workspaceGroup.toggleArchive", target={"kind": "workspaceGroup", "id": group_id})
    group_last = wait("group last", lambda: (lambda o: o if o and o.index("[G]") > o.index("Echo") and o.index("[G]") > o.index("Delta") else None)(order()), 10)
    check("Archive Group moves the group to the end of the list", bool(group_last), json.dumps(order()))
    header = next((r for r in rows() if (r.get("key") or "").startswith("group(")), None)
    check("the archived group header draws dimmed", bool(header and header.get("archived")), json.dumps(header and {k: header.get(k) for k in ("key", "archived")}))
    check("its members draw dimmed", all(archived(n) for n in ("Alpha", "Beta", "Gamma")))
    shot("3-group-archived")

    # The archives survive an app restart (the daemon's sidebar document keeps them).
    quit_app(app, "keep-sessions")
    app = launch()
    wait("rows back", lambda: set(ws) <= set(order()), 30)
    check("after an app restart: the group is still last and dimmed",
          bool(wait("still archived", lambda: archived("Alpha") and order()[-1] in ("Gamma", "[G]"), 15)), json.dumps(order()))
    shot("4-after-restart")
    run("workspaceGroup.toggleArchive", target={"kind": "workspaceGroup", "id": group_id})
    check("Unarchive Group restores the order", bool(wait("order restored", lambda: order() == before_order, 10)), json.dumps(order()))

    # The user's archive (palette, origin user) is one undo step.
    rpc("tab.focus", {"tab": None})
    focus = (topology().get("focus") or {}).get("workspace")
    say(f"  focused workspace: {focus}")
    target_name = next((n for n, i in ws.items() if i == focus), None)
    if target_name and palette_run("Archive/Unarchive Workspace"):
        check("the user's palette archive dims the focused workspace", bool(wait("archived", lambda: archived(target_name), 5)), target_name)
        key("z", ["command"])
        check("Cmd-Z undoes the user's archive", bool(wait("undone", lambda: not archived(target_name), 5)))
    else:
        check("the palette ran Archive/Unarchive Workspace", False, f"focus {focus}")
finally:
    if app and app.poll() is None:
        quit_app(app, "end-sessions")
    teardown.end()
    say(f"RESULT {len(FAILED)} failed: {json.dumps(FAILED)}")
    sys.exit(len(FAILED))
