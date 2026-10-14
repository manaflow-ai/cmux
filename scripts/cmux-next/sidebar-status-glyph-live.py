#!/usr/bin/env python3
"""Live check: the sidebar row's status marks are crisp, as tall as the unread badge and centered
on the title's line (Leo 2026-10-13, cosmic-gray: the green done check and the working mark read
tiny, blurry and low next to the "1" badge).

  scripts/cmux-next/sidebar-status-glyph-live.py --tag <tag>

Attaches to a running tagged app (it never launches, activates or quits one). It makes two
workspaces whose programs report done (left unseen) and working over OSC 7501, and reads the
sidebar's status glyphs (`debug.sidebar_rows` "status_glyphs"). For each state:

  1. the mark's mask is crisp at 1x and 2x (drawn at its pixel size, not resampled);
  2. the glyph box is as tall as the unread badge, and the drawn mark fills most of it;
  3. the drawn mark is centered on the title's cap height (half a device pixel).

Exits 1 when a check fails.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
TOLERANCE = 0.5
# The drawn mark's center against the title's capitals: half a device pixel (Leo saw base's
# 0.38 pt low at 10 pt as low); at 1x the pixel snap alone can move it half a point.
CENTER = {2: 0.25, 1: 0.5}
# Partly covered pixels per fully covered one. Drawn at its pixel size, a 10 pt mark measures about
# 1.1 at 1x and 0.4 at 2x (a 14 pt one 0.75 and 0.29); rendered at 2x and resampled, a 10 pt mark
# measured 7 to 12 at 1x and 1.3 to 1.5 at 2x.
SOFT_1X, SOFT_2X = 1.5, 0.6
# The drawn mark against the badge height: SF Symbols leave a small margin inside their box.
FILL = 0.75
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


def glyphs(state, name):
    """The status glyphs on the row titled `name` once it shows `state` (a few seconds at most)."""
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:  # bounded wait for the app to apply the report
        windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
        found = [g for w in windows for g in w.get("status_glyphs") or [] if g.get("state", "").startswith(state) and (g.get("title") or {}).get("text") == name]
        if found:
            return found
        time.sleep(0.25)
    return []


def check_glyph(glyph, label):
    print(f"{label}: {json.dumps(glyph)}", flush=True)
    soft1, soft2 = glyph.get("soft_1x"), glyph.get("soft_2x")
    check(soft1 is not None and soft1 <= SOFT_1X, f"{label}: crisp at 1x (soft {soft1} <= {SOFT_1X})")
    check(soft2 is not None and soft2 <= SOFT_2X, f"{label}: crisp at 2x (soft {soft2} <= {SOFT_2X})")
    badge = glyph["badge_height"]
    x, y, w, h = glyph["frame"]
    check(abs(h - badge) <= TOLERANCE, f"{label}: the glyph box is as tall as the badge ({h:g} vs {badge:g})")
    drawn = glyph.get("drawn")
    title = glyph.get("title")
    if not drawn or not title:
        check(False, f"{label}: the drawn mark and its row title are reported")
        return
    check(drawn[3] >= FILL * badge, f"{label}: the drawn mark fills the badge height ({drawn[3]:g} >= {FILL * badge:g})")
    center = drawn[1] + drawn[3] / 2
    tolerance = CENTER[2 if glyph.get("scale", 2) >= 2 else 1]
    check(abs(center - title["cap_center_y"]) <= tolerance,
          f"{label}: centered on the title's cap height ({center:.2f} vs {title['cap_center_y']:.2f})")


def terminals():
    return [word for word in cli("terminal", "list").stdout.split() if word.startswith("term_")]


def focused_terminal():
    """The terminal of the focused tab (`snapshot.get` topology)."""
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    tab_id = (topology.get("focus") or {}).get("tab")
    for ws in topology.get("workspaces") or []:
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id") == tab_id:
                        return next((v for v in tab.values() if isinstance(v, str) and v.startswith("term_")), None)
    return None


def new_workspace(name):
    """A new workspace named `name`, focused, and its terminal."""
    before = set(terminals())
    rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:  # bounded wait for the workspace's shell
        terminal = focused_terminal()
        if terminal and terminal not in before:
            cli("workspace", "current", "rename", name)
            time.sleep(1.0)  # the shell draws its first prompt
            return terminal
        time.sleep(0.5)
    return None


def report(terminal, state, tail=""):
    """An OSC 7501 record from the terminal's program (`tail` keeps a working program running)."""
    return cli("terminal", terminal, "write", "--text", f"printf '\\033]7501;state={state}\\033\\\\'{tail}\n")


def main():
    if "error" in (rpc("debug.sidebar_rows") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    # Done shows until the terminal is seen, so its workspace is made first and left behind.
    done = new_workspace("glyph-done")
    working = new_workspace("glyph-working")
    check(done is not None and working is not None, "two workspaces with a terminal each")
    for terminal, state, shown, name in ((done, "done", "success", "glyph-done"), (working, "working", "working", "glyph-working")):
        # A working record lasts while its program runs; done stays until it is seen.
        written = report(terminal or "", state, "; sleep 60" if state == "working" else "")
        check(written.returncode == 0, f"{state}: the program reports it ({written.stderr.strip()[-120:]})")
        found = glyphs(shown, name)
        check(bool(found), f"{state}: the {name} row shows the {shown} mark")
        for glyph in found[:1]:
            check_glyph(glyph, state)
    if working:
        cli("terminal", working, "write", "--text", "\x03")  # ends the sleep
    for terminal in (done, working):
        report(terminal or "", "idle")
    print(f"{len(failures)} failure(s)", flush=True)
    sys.exit(1 if failures else 0)


main()
