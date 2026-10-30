#!/usr/bin/env python3
"""Live check that actions which release main-actor objects keep the app running (cx-t7hu, cx-bpcj) on
a running tagged cmux-next build.

Home is a top page: showing it takes the workspace's layout view out of the window, which
detaches that view's display-link client. That release used to trap the app (SIGTRAP in the
client's isolated deinit). The script seeds the showcase workspaces, then goes from a workspace
to Home and back a few times through `home.show` and `workspace.selectFirst`, as the palette and
the CLI run them, and checks after each step that the app still answers and shows what was
asked for. Then it opens Search Tabs (`tab.search`) several times in a row: each run resets the
palette, which releases the previous page inside the action (that release trapped too, though
not every time), and Escape closes it. Last it sets a tab's icon a few times (`tab.setIcon`);
each change releases its undo toast's window holder inside the action, and that release trapped
in the cx-bpcj report. These traps depend on allocator state, so a passing run is not proof that
a build is free of them; a failing run is.

It attaches to an app already running (a capture slot's `capture-host launch`, or a tagged
build) through its debug socket. It never launches or quits the app.

Usage: action-release-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--rounds 3] [--search-rounds 8] [--icon-rounds 3]
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--search-rounds", type=int, default=8)
parser.add_argument("--icon-rounds", type=int, default=3)
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=30):
    """One line-JSON request on the app's control socket; an error dict when it does not answer."""
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
        return {"error": str(error), "unreachable": True}


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


def alive():
    return bool((rpc("debug.windows", timeout=5) or {}).get("windows"))


def selected():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    window = windows[0] if windows else {}
    active = [item.get("id") for item in window.get("items") or [] if item.get("active")]
    return tuple(window.get("selection") or []) or tuple(active)


def any_tab():
    """The selected tab of the first pane that has one (the target of tab.setIcon)."""
    panes = [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]
    return next((p.get("selected_tab") for p in panes if p.get("selected_tab")), None)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def main():
    if not wait(alive, 60):
        sys.exit("the app does not answer on " + opts.socket)
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("debug.showcase.seed")
    wait(lambda: selected() and not selected()[0].startswith("itm_"), 15)
    for step in range(1, opts.rounds + 1):
        reply = rpc("action.run", {"action": "home.show"})
        shown = wait(lambda: selected() == ("itm_home",), 15)
        up = alive()
        row(f"round {step}: home.show", "the app answers and shows Home",
            f"alive={up} selection={selected() if up else '-'} reply={json.dumps(reply)[:160]}", up and bool(shown))
        if not up:
            return
        rpc("action.run", {"action": "workspace.selectFirst"})
        back = wait(lambda: selected() and not selected()[0].startswith("itm_"), 15)
        up = alive()
        row(f"round {step}: back to a workspace", "the app answers and shows the workspace",
            f"alive={up} selection={selected() if up else '-'}", up and bool(back))
        if not up:
            return
    for step in range(1, opts.search_rounds + 1):
        reply = rpc("action.run", {"action": "tab.search", "focus": True})  # it opens only when focus is requested
        time.sleep(1)  # test harness: let the palette page settle
        up = alive()
        row(f"search {step}: tab.search", "the palette opens and the app answers",
            f"alive={up} reply={json.dumps(reply)[:160]}", up and "error" not in (reply or {}))
        if not up:
            return
    rpc("debug.key", {"key": "escape"})
    rpc("action.run", {"action": "workspace.selectFirst"})
    wait(lambda: selected() and not selected()[0].startswith("itm_"), 15)
    tab = wait(any_tab, 15)
    if not tab:  # the seeded workspaces may show no live pane: open a workspace with one terminal pane
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
        tab = wait(any_tab, 15)
    if not tab:
        row("icon: a tab to change", "a pane with a selected tab", json.dumps((rpc("debug.surfaces") or {}).get("windows"))[:400], False)
        return
    for step, icon in zip(range(1, opts.icon_rounds + 1), ["star", "flame", "bolt", "heart", "leaf"] * 4):
        reply = rpc("action.run", {"action": "tab.setIcon", "target": f"tab:{tab}", "args": {"icon": icon}})
        time.sleep(1)  # test harness: let the change settle (a script origin offers no undo toast)
        up = alive()
        row(f"icon {step}: tab.setIcon {icon}", "the icon changes and the app answers",
            f"alive={up} reply={json.dumps(reply)[:160]}", up and "error" not in (reply or {}))
        if not up:
            return


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
