#!/usr/bin/env python3
"""Live check that rapid workspace create and close never race (cx-7cit9).

Leo 2026-10-12: Cmd-N at key-repeat speed outran creation. The sidebar showed workspace-2,
then 7..16 (3-6 missing), New Tab listed stale "about:blank workspace-7" rows, and a raw
"no workspace <uuid>" HUD appeared; closing while creates were in flight misbehaved.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It presses 30 Cmd-N at key-repeat speed through
`debug.key`, with a Cmd-Shift-W after every third, some of them in the same instant as the
Cmd-N before them, so a close lands on a workspace still being created. Once the app settles
it checks that:
  - the window's sidebar rows and the daemon's `list-workspaces` hold the same workspaces
    (less the ones the sidebar never shows, such as Home), the new ones in press order;
  - the new workspaces that remain are numbered without a gap;
  - a New Tab page would suggest only tabs and workspaces that exist, none titled about:blank;
  - no refusal HUD or toast appeared during the burst (`debug.toast` `refusals`).
It writes a window snapshot before and after the burst (`rapid-workspace-before.png`,
`rapid-workspace-after.png`) to --out, and never launches or quits the app.

Usage: rapid-workspace-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--daemon-socket PATH] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, re, socket, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--daemon-socket", help="the app's daemon socket (default: derived from --socket)")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--creates", type=int, default=30)
parser.add_argument("--interval", type=float, default=0.033, help="seconds between key presses (key repeat)")
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
    """One request on the app's control socket."""
    try:
        reply = line_json(opts.socket, {"id": 1, "method": method, "params": params or {}}, timeout)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def daemon_socket():
    if opts.daemon_socket:
        return opts.daemon_socket
    temp = os.environ.get("TMPDIR") or subprocess.run(
        ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    session = os.path.basename(opts.socket).replace("cmux-debug-", "cmux-app-", 1)
    return os.path.join(temp, f"cmux-tui-{os.getuid()}", session)


HIDDEN = set()  # ids of daemon workspaces no sidebar row shows at the start (Home)


def daemon_workspaces(hidden=False):
    """The daemon's workspaces, less the ones the sidebar never shows unless `hidden`."""
    snapshot = line_json(daemon_socket(), {"id": 1, "cmd": "list-workspaces"}, 30)
    return [w for w in (snapshot.get("data") or {}).get("workspaces") or [] if hidden or not ids(w) & HIDDEN]


def ids(entry):
    """Every string id the daemon gives a workspace (the sidebar keys rows by one of them)."""
    return {v for k, v in entry.items() if isinstance(v, str) and ("id" in k or k == "key") and v}


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


def sidebar_rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    rows = windows[0].get("rows") or [] if windows else []
    return [r for r in rows if str(r.get("key", "")).startswith("workspace(")]


def row_id(r):
    found = re.search(r"workspace\(([^)]*)\)", str(r.get("key")))
    return found.group(1) if found else str(r.get("key"))


def number(name):
    found = re.fullmatch(r"workspace-(\d+)", name or "")
    return int(found.group(1)) if found else None


def press(key, modifiers):
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers}, timeout=10)
    return reply if isinstance(reply, dict) else {}


def snapshot(name):
    path = os.path.join(opts.out, name)
    reply = rpc("debug.window_snapshot", {"path": path, "webviews": False}, timeout=30) or {}
    print(f"snapshot {name}: {reply.get('path') or reply.get('error')}", flush=True)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def watch_toasts(stop, seen):
    """Toasts come and go: poll them through the burst and the settle."""
    while not stop.is_set():
        for window in (rpc("debug.toast", timeout=5) or {}).get("windows") or []:
            for toast in window.get("toasts") or []:
                seen.setdefault(toast.get("id"), toast.get("message"))
        time.sleep(0.1)  # test harness polling a live app


def settled(before_count, expected_new):
    """The daemon holds the expected count and the sidebar lists the same keys, twice in a row."""
    def same():
        daemon = daemon_workspaces()
        rows = sidebar_rows()
        if len(daemon) != before_count + expected_new or len(rows) != len(daemon):
            return None
        return daemon, rows
    first = wait(same, 45)
    time.sleep(2)  # test harness: nothing still in flight changes it
    return same() if first else None


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    shown = {row_id(r) for r in sidebar_rows()}
    HIDDEN.update(*(ids(w) for w in daemon_workspaces() if not ids(w) & shown))
    before = daemon_workspaces()
    before_ids = set().union(*(ids(w) for w in before)) if before else set()
    refusals_before = len((rpc("debug.toast") or {}).get("refusals") or [])
    print(f"before: {len(before)} workspaces ({len(HIDDEN)} hidden ids), {refusals_before} refusals", flush=True)
    snapshot("rapid-workspace-before.png")

    stop, seen = threading.Event(), {}
    watcher = threading.Thread(target=watch_toasts, args=(stop, seen), daemon=True)
    watcher.start()
    closes = 0
    for index in range(1, opts.creates + 1):
        press("n", ["cmd"])
        if index % 3 == 0:
            # Every sixth close follows its Cmd-N at once: it lands on a workspace being created.
            if index % 6 != 0:
                time.sleep(opts.interval)  # key repeat cadence
            press("w", ["cmd", "shift"])
            closes += 1
        time.sleep(opts.interval)  # key repeat cadence
    expected_new = opts.creates - closes
    print(f"pressed {opts.creates} Cmd-N and {closes} Cmd-Shift-W; expecting {expected_new} new workspaces", flush=True)

    state = settled(len(before), expected_new)
    stop.set()
    watcher.join(timeout=5)
    snapshot("rapid-workspace-after.png")
    daemon = daemon_workspaces()
    rows = sidebar_rows()
    row("daemon count", len(before) + expected_new, len(daemon), state is not None and len(daemon) == len(before) + expected_new)

    # The sidebar lists the daemon's workspaces, and the new ones in the order they were
    # pressed (newest first with the default `top` placement, oldest first with `bottom`).
    sidebar_ids = [row_id(r) for r in rows]
    daemon_order = [next((i for i in ids(w) if i in sidebar_ids), None) for w in daemon]
    row("sidebar matches daemon", "same workspaces", f"sidebar={len(rows)} daemon={len(daemon)} "
        f"missing={[w.get('name') for w, i in zip(daemon, daemon_order) if i is None]}",
        None not in daemon_order and len(rows) == len(daemon))
    by_id = {i: number(w.get("name")) for w in daemon for i in ids(w)}
    shown_new = [by_id.get(i) for i in sidebar_ids if i in by_id and not {i} & before_ids]
    shown_new = [n for n in shown_new if n is not None]
    in_order = shown_new in (sorted(shown_new), sorted(shown_new, reverse=True))
    row("new rows in press order", "monotonic workspace numbers", shown_new, bool(shown_new) and in_order)

    # The new workspaces that remain are numbered without a gap.
    new = [w for w in daemon if not ids(w) & before_ids]
    numbers = sorted(n for n in (number(w.get("name")) for w in new) if n is not None)
    gapless = bool(numbers) and numbers == list(range(numbers[0], numbers[0] + len(numbers)))
    row("new workspace numbers", "consecutive", numbers, gapless and len(numbers) == expected_new)

    # A New Tab page suggests only what exists.
    page = rpc("debug.new_tab", {"action": "state"}) or {}
    names = {w.get("name") for w in daemon_workspaces(hidden=True)}
    stale_tabs = [t for t in page.get("omnibar_tabs") or [] if t.get("title") == "about:blank" or t.get("workspace") not in names]
    stale_workspaces = [w for w in page.get("omnibar_workspaces") or [] if w.get("name") not in names]
    row("New Tab suggestions", "only live tabs and workspaces, no about:blank",
        f"stale tabs={stale_tabs[:4]} stale workspaces={stale_workspaces[:4]}",
        "omnibar_tabs" in page and not stale_tabs and not stale_workspaces)

    refusals = ((rpc("debug.toast") or {}).get("refusals") or [])[refusals_before:]
    row("no refusal HUD", "none", refusals[:5], not refusals)
    row("no toast", "none", list(seen.values())[:5], not seen)

    passed = sum(ROWS)
    print(f"RESULT {passed}/{len(ROWS)}", flush=True)
    return 0 if passed == len(ROWS) else 1


if __name__ == "__main__":
    sys.exit(main())
