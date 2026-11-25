#!/usr/bin/env python3
"""Live check of Add Group to Section (cx-a9h6 follow-up) on a running tagged cmux-next build.

`workspaceGroup.addToSection` adds every workspace of a group to a sidebar section as workspace
items (the same items Add to Sidebar makes for one workspace), in one undo step. A member already
in that section is not added twice; when every member is there, the action is refused. An unknown
section is refused. Groups have no Show Group in Finder: a group is a set of workspaces, not a
folder, so `workspaceGroup.revealInFinder` is an unknown action (`not_found`).

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It makes a two-workspace group and a titled section,
runs the action the way the palette does (`action.run`, the section named by its title, as the
CLI may), and reads the workspace items of that section from `debug.sidebar_rows` `items` (`section_title`). It never
launches or quits the app.

Usage: workspace-group-section-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


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


def windows():
    return (rpc("debug.sidebar_rows") or {}).get("windows") or []


def row_of(entry):
    """The workspace's row in the first window that lists it."""
    for window in windows():
        rows = [r for r in window.get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]
        found = next((r for r in rows if any(i in str(r.get("key")) for i in ids(entry))), None)
        if found:
            return found
    return None


def target_of(entry):
    """An action target for a workspace: its public id."""
    return "workspace:" + next((v for v in sorted(ids(entry)) if v.startswith("ws_")), sorted(ids(entry))[0])


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def workspace_items(section_title):
    """The workspace items of the section titled `section_title` (`debug.sidebar_rows` `items`)."""
    items = (windows() or [{}])[0].get("items") or []
    return [i for i in items if i.get("ref_kind") == "workspace" and i.get("section_title") == section_title]


def holds(item, entry):
    """A workspace item names the workspace by `session:resource`."""
    ref = str(item.get("ref", ""))
    return any(ref.endswith(":" + i) for i in ids(entry))


def refused(reply):
    """The action ran and refused (an error that is not `not_found`, the unknown-action error)."""
    error = (reply or {}).get("error")
    return bool(error) and not (isinstance(error, dict) and error.get("code") == "not_found")


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)

    # A group of two workspaces.
    before = known()
    print("workspace.newAtBottom:", action("workspace.newAtBottom"), flush=True)
    first = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    if not first:
        sys.exit("no workspace opened")
    print("workspace.moveToNewGroup:", action("workspace.moveToNewGroup", {"name": "section e2e"}, target=target_of(first)), flush=True)
    group = wait(lambda: (row_of(first) or {}).get("group"), 10)
    before = known()
    print("workspace.newBelow:", action("workspace.newBelow", target=target_of(first)), flush=True)
    second = (wait(lambda: new_workspaces(before), 20) or [None])[0]
    joined = second and wait(lambda: (row_of(second) or {}).get("group") == group, 10)
    if not group or not joined:
        sys.exit(f"no two-workspace group: group {group}, second joined {joined}")
    members = [first, second]

    # A new section in the top region, named so the action can find it by title.
    title = f"Group section e2e {int(time.time())}"
    print("sidebar.section.add:", action("sidebar.section.add", {"title": title, "region": "top"}), flush=True)
    time.sleep(1)  # test harness: the layout applies

    held_before = [i for i in workspace_items(title) if any(holds(i, m) for m in members)]
    reply = action("workspaceGroup.addToSection", {"section": title}, target="workspace-group:" + group)
    added = wait(lambda: (lambda now: now if all(any(holds(i, m) for i in now) for m in members) else None)(
        [i for i in workspace_items(title) if any(holds(i, m) for m in members)]), 10) or []
    row("Add Group to Section adds every member to the section", "a workspace item for each of the 2 members",
        f"reply {reply}; member items before {len(held_before)}, after {len(added)}",
        "error" not in (reply or {}) and len(added) - len(held_before) == len(members))

    again = action("workspaceGroup.addToSection", {"section": title}, target="workspace-group:" + group)
    row("Adding it again is refused, not duplicated", "an error naming the members already there; no new items",
        f"reply {again}; member items {len([i for i in workspace_items(title) if any(holds(i, m) for m in members)])}",
        refused(again) and len([i for i in workspace_items(title) if any(holds(i, m) for m in members)]) == len(added))

    unknown = action("workspaceGroup.addToSection", {"section": "no such section e2e"}, target="workspace-group:" + group)
    row("An unknown section is refused", "a refusal", f"reply {unknown}", refused(unknown))

    finder = action("workspaceGroup.revealInFinder", target="workspace-group:" + group)
    row("Groups have no Show Group in Finder", "an unknown-action error (not_found)", f"reply {finder}",
        isinstance((finder or {}).get("error"), dict) and finder["error"].get("code") == "not_found")
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "workspace-group-section.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
