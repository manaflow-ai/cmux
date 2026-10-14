#!/usr/bin/env python3
"""Live check of the sidebar status follow-ups from hq-2d's state matrix (2026-10-14,
.cmux-scratch/sidebar-rewrite/states): beads cx-lko8w, cx-ldocj, cx-yuzqk, cx-on7iu, cx-htbe5.

  scripts/cmux-next/sidebar-status-matrix-live.py --tag <tag> --config <the app's cmux.json> [--frames DIR]

Attaches to a running tagged app (it never launches or quits one) and reads `debug.sidebar_rows`:

  status set:  `cmux status set --state busy --progress 40%` draws a 40% ring on its row, and
               `--state waiting` the needs-input mark (cx-lko8w);
  badge:       a row whose only news is its status (OSC 7501 done, blocked) draws no badge; a row
               with an OSC 9 notification draws a count (cx-ldocj);
  bell:        a bell in a background workspace's terminal marks its row like a notification (cx-on7iu);
  focus:       focusing the done row's workspace in the active app clears its done mark (cx-yuzqk);
  minimal:     with `sidebar.minimal` on, a working row keeps its spinner and an OSC 9;4 row its
               progress bar (cx-htbe5).

The focus step brings the tagged app's window to the front (`showMainWindow`): run it on a GUI lane
host only. `--only` limits the run to some checks (comma list of the names above).
Exits 1 when a check fails.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--config", required=True, help="the cmux.json the app reads (CMUX_NEXT_CONFIG_FILE)")
parser.add_argument("--frames", help="write window snapshots here")
parser.add_argument("--only", default="status,badge,bell,focus,minimal")
opts = parser.parse_args()
ONLY = set(opts.only.split(","))
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args):
    env = dict(os.environ, CMUX_TAG=opts.tag)
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)


def focus():
    snap = rpc("snapshot.get") or {}
    return ((snap.get("topology") or snap).get("focus") or {})


def terminal_of(tab_id):
    snap = rpc("snapshot.get") or {}
    for ws in (snap.get("topology") or snap).get("workspaces") or []:
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id") == tab_id:
                        return next((v for v in tab.values() if isinstance(v, str) and v.startswith("term_")), None)
    return None


def new_workspace(name):
    """A new focused workspace named `name`: (its tab id, its terminal)."""
    before = focus().get("tab")
    rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:  # bounded wait for the workspace's shell
        tab = focus().get("tab")
        terminal = terminal_of(tab) if tab and tab != before else None
        if terminal:
            cli("workspace", "current", "rename", name)
            time.sleep(1.0)  # the shell draws its first prompt
            return tab, terminal
        time.sleep(0.5)
    return None, None


def write(terminal, text):
    return cli("terminal", terminal or "", "write", "--text", text)


def osc7501(terminal, state, tail=""):
    return write(terminal, f"printf '\\033]7501;state={state}\\033\\\\'{tail}\n")


def row(name):
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return next((dict(r, window=w.get("window")) for w in windows for r in w.get("rows") or [] if r.get("title") == name), None)


def glyph(name):
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return next((g for w in windows for g in w.get("status_glyphs") or [] if (g.get("title") or {}).get("text") == name), None)


def until(probe, seconds=8):
    """`probe()` once it is truthy, else its last value (a bounded wait for the app to apply a report)."""
    deadline = time.monotonic() + seconds
    value = probe()
    while not value and time.monotonic() < deadline:
        time.sleep(0.25)
        value = probe()
    return value


def show_window():
    rpc("action.run", {"action": "showMainWindow", "origin": "script"})


def snapshot(label):
    if opts.frames:
        os.makedirs(opts.frames, exist_ok=True)
        shot = rpc("debug.window_snapshot", {"path": os.path.join(opts.frames, f"{label}.png"), "webviews": False})
        print(f"snapshot {label}: {json.dumps(shot)[:160]}", flush=True)


ORIGINAL_CONFIG = open(opts.config).read() if os.path.exists(opts.config) else None


def set_config(values):
    """Merge `values` into the app's cmux.json (written whole by rename, so the watcher never reads half a file)."""
    try:
        current = json.loads(ORIGINAL_CONFIG or "{}")
    except ValueError:
        current = {}
    for key, value in values.items():
        current[key] = {**current.get(key, {}), **value} if isinstance(value, dict) else value
    temp = opts.config + ".tmp"
    with open(temp, "w") as out:
        json.dump(current, out)
    os.replace(temp, opts.config)


def restore_config():
    if ORIGINAL_CONFIG is not None:
        temp = opts.config + ".tmp"
        with open(temp, "w") as out:
            out.write(ORIGINAL_CONFIG)
        os.replace(temp, opts.config)


def main():
    if "error" in (rpc("debug.sidebar_rows") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    made = {}
    for name in ("mx-done", "mx-blocked", "mx-notify", "mx-bell", "mx-busy", "mx-waiting", "mx-working", "mx-progress"):
        made[name] = new_workspace(name)
    check(all(t for t, _ in made.values()), "eight workspaces with a terminal each")
    term = {name: terminal for name, (_, terminal) in made.items()}

    if "status" in ONLY:
        # `--target current` is the focused workspace: focus each named one first.
        cli("tab", made["mx-busy"][0] or "", "focus")
        until(lambda: focus().get("tab") == made["mx-busy"][0], 5)
        written = cli("status", "set", "mx-build", "--label", "Build", "--state", "busy", "--progress", "40%", "--target", "current")
        check(written.returncode == 0, f"status set busy 40%: accepted ({(written.stderr or written.stdout).strip()[-160:]})")
        cli("tab", made["mx-waiting"][0] or "", "focus")
        until(lambda: focus().get("tab") == made["mx-waiting"][0], 5)
        written = cli("status", "set", "mx-ask", "--label", "Needs you", "--state", "waiting", "--target", "current")
        check(written.returncode == 0, f"status set waiting: accepted ({(written.stderr or written.stdout).strip()[-160:]})")
        busy = until(lambda: (lambda g: g if g and "ring" in g.get("glyph", "") else None)(glyph("mx-busy")))
        print(f"mx-busy glyph: {json.dumps(glyph('mx-busy'))}", flush=True)
        check(bool(busy) and "0.4" in busy.get("glyph", ""), "status set --state busy --progress 40%: the row draws a 40% ring")
        waiting = until(lambda: (lambda g: g if g and g.get("state", "").startswith("waiting") else None)(glyph("mx-waiting")))
        print(f"mx-waiting glyph: {json.dumps(glyph('mx-waiting'))}", flush=True)
        check(bool(waiting), "status set --state waiting: the row draws the needs-input mark")

    if "badge" in ONLY or "focus" in ONLY:
        osc7501(term["mx-done"], "done")
        osc7501(term["mx-blocked"], "blocked:kind=permission", "; sleep 300")
        write(term["mx-notify"], "printf '\\033]9;mx notify\\033\\\\'\n")
        until(lambda: glyph("mx-done") and glyph("mx-blocked"))
        until(lambda: (row("mx-notify") or {}).get("unread", "none") != "none")
        for name in ("mx-done", "mx-blocked"):
            r = row(name) or {}
            print(f"{name}: unread {r.get('unread')} activity {r.get('activity')}", flush=True)
            check(r.get("unread") == "none", f"badge: {name} (a status alone) draws no badge (unread {r.get('unread')})")
        r = row("mx-notify") or {}
        check(str(r.get("unread", "")).startswith("count"), f"badge: mx-notify (an OSC 9 notification) draws a count (unread {r.get('unread')})")

    if "bell" in ONLY:
        write(term["mx-bell"], "printf '\\a'\n")
        marked = until(lambda: (row("mx-bell") or {}).get("unread", "none") != "none", 6)
        r = row("mx-bell") or {}
        check(bool(marked), f"bell: a bell in a background terminal marks its row (unread {r.get('unread')})")

    snapshot("statuses")

    if "focus" in ONLY:
        show_window()
        time.sleep(1)  # test script: the window comes to the front
        cli("tab", made["mx-done"][0] or "", "focus")
        focused = until(lambda: focus().get("tab") == made["mx-done"][0], 5)
        check(bool(focused), "focus: the done row's tab is focused")
        cleared = until(lambda: glyph("mx-done") is None, 6)
        r = row("mx-done") or {}
        print(f"mx-done after focus: activity {r.get('activity')} unread {r.get('unread')} glyph {json.dumps(glyph('mx-done'))}", flush=True)
        check(bool(cleared), "focus: focusing the done row's workspace clears its done mark")
        snapshot("focused-done")

    if "minimal" in ONLY:
        osc7501(term["mx-working"], "working", "; sleep 300")
        write(term["mx-progress"], "printf '\\033]9;4;1;40\\033\\\\'; sleep 300\n")
        until(lambda: (row("mx-progress") or {}).get("progress"))
        set_config({"sidebar": {"minimal": True}})
        working = until(lambda: (lambda g: g if g and g.get("glyph") == "arc" else None)(glyph("mx-working")))
        r = row("mx-working") or {}
        print(f"minimal mx-working: {json.dumps(r)[:300]} glyph {json.dumps(glyph('mx-working'))}", flush=True)
        check(bool(working), "minimal: a working row keeps its spinner")
        progress = until(lambda: (row("mx-progress") or {}).get("progress"))
        check(bool(progress), f"minimal: an OSC 9;4 row keeps its progress bar ({json.dumps(row('mx-progress'))[:200]})")
        snapshot("minimal")
        restore_config()

    for name in ("mx-blocked", "mx-working", "mx-progress"):
        write(term[name], "\x03")
    for name in ("mx-busy", "mx-waiting"):
        cli("tab", made[name][0] or "", "focus")
        cli("status", "clear", "--all", "--target", "current")
    print(f"{len(failures)} failure(s)", flush=True)
    sys.exit(1 if failures else 0)


try:
    main()
finally:
    restore_config()
