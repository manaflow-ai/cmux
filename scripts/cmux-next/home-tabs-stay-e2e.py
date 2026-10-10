#!/usr/bin/env python3
"""Live check that Home's tabs stay in Home (briefs/rapid-switch-1009 item 2) on a running tagged
cmux-next build.

Move Tab to New Workspace and Move Tab to New Window, run on Home's tab through the control
socket as the palette and CLI run them, are refused, and no workspace or window appears. A tab
of another workspace still moves to a new workspace. The script attaches to an app already
running (a capture slot's `capture-host launch`, or a tagged build) on Home, through its debug
socket. It never launches or quits the app.

Usage: home-tabs-stay-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
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


def sidebar():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def selected():
    window = sidebar()
    active = [item.get("id") for item in window.get("items") or [] if item.get("active")]
    return tuple(window.get("selection") or []) or tuple(active)


def workspaces():
    return len([r for r in sidebar().get("rows") or [] if str(r.get("key", "")).startswith("workspace(")])


def windows():
    return len((rpc("debug.windows") or {}).get("windows") or [])


def focused_tab():
    panes = [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]
    return next((p.get("selected_tab") for p in panes if p.get("focused")), None)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def promote(name, tab, count):
    """Runs a promote action on `tab`; returns its reply and the count after it settled."""
    reply = rpc("action.run", {"action": name, "target": f"tab:{tab}"})
    time.sleep(4)  # test harness: a move that ran has landed by now
    return reply, count()


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    if not wait(lambda: selected() == ("itm_home",) and focused_tab(), 30):
        print("show Home:", rpc("action.run", {"action": "home.show"}), flush=True)
    home_tab = wait(lambda: selected() == ("itm_home",) and focused_tab(), 30)
    if not home_tab:
        sys.exit(f"Home is not shown with a tab: {selected()}")
    print("Home's tab:", home_tab, flush=True)

    before = workspaces()
    reply, after = promote("palette.moveTabToNewWorkspace", home_tab, workspaces)
    row("Move Tab to New Workspace on Home's tab", "refused; no new workspace",
        f"reply={json.dumps(reply)[:240]} workspaces {before} -> {after}", "error" in (reply or {}) and after == before)
    before = windows()
    reply, after = promote("tab.moveToNewWindow", home_tab, windows)
    row("Move Tab to New Window on Home's tab", "refused; no new window",
        f"reply={json.dumps(reply)[:240]} windows {before} -> {after}", "error" in (reply or {}) and after == before)

    rpc("action.run", {"action": "workspace.selectFirst"})
    other = wait(lambda: not selected()[0].startswith("itm_") and focused_tab(), 15)
    rpc("action.run", {"action": "newSurface"})
    wait(lambda: focused_tab() and focused_tab() != other, 15)
    tab = focused_tab()
    before = workspaces()
    reply, after = promote("palette.moveTabToNewWorkspace", tab, workspaces)
    row("Move Tab to New Workspace on another workspace's tab", "runs; one more workspace",
        f"reply={json.dumps(reply)[:240]} workspaces {before} -> {after}", "error" not in (reply or {}) and after == before + 1)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "home-tabs-stay.png")})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
