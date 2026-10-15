#!/usr/bin/env python3
"""Live check: the sidebar row's status marks are crisp, as tall as the unread badge and centered
on the title's line (Leo 2026-10-13, cosmic-gray: the green done check and the working mark read
tiny, blurry and low next to the "1" badge), and an agent working draws a spinner, not a pulsing
mark (Lawrence 2026-10-14: "left sidebar needs to be a spinner instead of flash", cx-qtgj2).

  scripts/cmux-next/sidebar-status-glyph-live.py --tag <tag> [--pid <app pid>] [--frames DIR]

Attaches to a running tagged app (it never launches or quits one). It makes workspaces whose
programs report done (left unseen), blocked (needs input) and working over OSC 7501, and one that
runs htop (no report), and reads the sidebar's status glyphs (`debug.sidebar_rows`
"status_glyphs"). Checks:

  done, needs input: the mark is crisp at 1x and 2x, as tall as the badge, on the title's line,
                     and still (no animation);
  working:           the glyph is the arc and it spins; its box is as tall as the badge and on the
                     title's line;
  synced:            three working rows, one started later, are at the same rotation phase
                     (Lawrence 2026-10-14: "all spinners need to be synced");
  htop:              its row shows no status glyph (a full-screen program is not agent work);
  minimized:         with the window minimized the working arc stops (no CPU for a hidden spinner),
                     and spins again once the window shows (`showMainWindow` brings the tagged
                     app's window to the front: run it on a GUI lane host only).

With --pid it also reports the app's CPU share over 15 s windows: no row working, one row working
(visible), and the window minimized. With --frames it writes window snapshots of the spinning row
(`debug.window_snapshot`) to DIR. Exits 1 when a check fails.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--pid", type=int, help="the app's pid: report its CPU share per scenario")
parser.add_argument("--frames", help="write window snapshots of the spinning row here")
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


def check_glyph(glyph, label, crisp=True):
    print(f"{label}: {json.dumps(glyph)}", flush=True)
    soft1, soft2 = glyph.get("soft_1x"), glyph.get("soft_2x")
    if crisp:
        check(soft1 is not None and soft1 <= SOFT_1X, f"{label}: crisp at 1x (soft {soft1} <= {SOFT_1X})")
        check(soft2 is not None and soft2 <= SOFT_2X, f"{label}: crisp at 2x (soft {soft2} <= {SOFT_2X})")
    else:
        print(f"note {label}: softness not checked (1x {soft1}, 2x {soft2})", flush=True)
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


def find_glyphs(name):
    """Every status glyph on the row titled `name` now, with the id of the window it is in."""
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return [dict(g, window=w.get("window")) for w in windows for g in w.get("status_glyphs") or []
            if (g.get("title") or {}).get("text") == name]


def animation_on(name, window, wanted):
    """The animation of `name`'s glyph in `window` once it equals `wanted` (a few seconds at most)."""
    deadline = time.monotonic() + 8
    current = None
    while time.monotonic() < deadline:  # bounded wait for the occlusion change to reach the row
        found = [g for g in find_glyphs(name) if g.get("window") == window]
        current = found[0].get("animation") if found else "no glyph"
        if current == wanted:
            break
        time.sleep(0.25)
    return current


def action(name):
    reply = rpc("action.run", {"action": name, "origin": "script"})
    error = reply.get("error") if isinstance(reply, dict) else None
    # A reply deadline with the action still running is a run, not a refusal.
    running = isinstance(error, dict) and error.get("code") == "timeout" and (error.get("data") or {}).get("not_run") is False
    check(error is None or running, f"action {name} runs ({json.dumps(reply)[:160]})")


def spinning(name):
    """`name`'s glyph once it spins. A shared GUI host stacks other jobs' windows over this one,
    and a covered window stops its spinners (that is the energy rule), so this brings the tagged
    app's window to the front and waits a few seconds for the spin."""
    deadline = time.monotonic() + 15
    glyph = None
    while time.monotonic() < deadline:  # bounded wait for the window to show
        found = find_glyphs(name)
        glyph = found[0] if found else None
        if glyph and glyph.get("animation") == "spin":
            return glyph
        action("showMainWindow")
        time.sleep(1)
    return glyph


def check_spinner(glyph, label):
    print(f"{label}: {json.dumps(glyph)}", flush=True)
    check(glyph.get("glyph") == "arc", f"{label}: the glyph is the spinner arc (got {glyph.get('glyph')})")
    check(glyph.get("animation") == "spin", f"{label}: the arc spins (animation {glyph.get('animation')})")
    badge = glyph["badge_height"]
    x, y, w, h = glyph["frame"]
    check(abs(h - badge) <= TOLERANCE, f"{label}: the spinner box is as tall as the badge ({h:g} vs {badge:g})")
    title = glyph.get("title")
    if not title:
        check(False, f"{label}: its row title is reported")
        return
    tolerance = CENTER[2 if glyph.get("scale", 2) >= 2 else 1]
    check(abs(y + h / 2 - title["cap_center_y"]) <= tolerance,
          f"{label}: centered on the title's cap height ({y + h / 2:.2f} vs {title['cap_center_y']:.2f})")


def cpu(label, seconds=15):
    """The app's CPU share over `seconds` (proc_pid_rusage user + system time)."""
    if not opts.pid:
        return
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_idle import usage  # noqa: E402
    before, t0 = usage(opts.pid), time.monotonic()
    time.sleep(seconds)  # test script: the measurement window itself
    after, wall = usage(opts.pid), time.monotonic() - t0
    if before and after:
        print(f"cpu {label}: {100.0 * (after[0] - before[0]) / (wall * 1e9):.3f}% over {wall:.1f} s, "
              f"{(after[1] - before[1]) / wall:.1f} wakeups/s", flush=True)


def snapshots(name):
    """Window snapshots of the spinning row, back to back."""
    if not opts.frames:
        return
    os.makedirs(opts.frames, exist_ok=True)
    found = find_glyphs(name)
    if found:
        with open(os.path.join(opts.frames, "glyph.json"), "w") as out:
            json.dump(found[0], out, indent=2)
    for index in range(12):
        shot = rpc("debug.window_snapshot", {"path": os.path.join(opts.frames, f"frame-{index:02d}.png"), "webviews": False})
        print(f"frame {index}: {json.dumps(shot)[:200]}", flush=True)


def main():
    if "error" in (rpc("debug.sidebar_rows") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    cpu("no row working")
    # Done shows until the terminal is seen, so its workspace is made first and left behind.
    done = new_workspace("glyph-done")
    blocked = new_workspace("glyph-needs-input")
    top = new_workspace("glyph-htop")
    # htop runs from here on: by its check it has run through every other step.
    written = cli("terminal", top or "", "write", "--text", "htop || top\n")
    check(written.returncode == 0, f"htop: started ({written.stderr.strip()[-120:]})")
    working = [new_workspace(name) for name in ("glyph-working", "glyph-working-2", "glyph-working-late")]
    check(None not in (done, blocked, top, *working), "six workspaces with a terminal each")
    # A working or blocked record lasts while its program runs; done stays until it is seen.
    for terminal, state, shown, name in ((done, "done", "success", "glyph-done"),
                                         (blocked, "blocked:kind=permission", "waiting", "glyph-needs-input")):
        written = report(terminal or "", state, "; sleep 120" if state.startswith("blocked") else "")
        check(written.returncode == 0, f"{state}: the program reports it ({written.stderr.strip()[-120:]})")
        found = glyphs(shown, name)
        check(bool(found), f"{state}: the {name} row shows the {shown} mark")
        for glyph in found[:1]:
            # The needs-input hand is unchanged by cx-qtgj2 and reads soft at 1x (Leo's crispness
            # work covered done and working); only done keeps the softness bounds here.
            check_glyph(glyph, state, crisp=state == "done")
            check(glyph.get("glyph") == "mark", f"{state}: a status mark, not the spinner (got {glyph.get('glyph')})")
            check(glyph.get("animation") is None, f"{state}: the mark is still (animation {glyph.get('animation')})")
    for terminal in working[:2]:
        written = report(terminal or "", "working", "; sleep 120")
        check(written.returncode == 0, f"working: the program reports it ({written.stderr.strip()[-120:]})")
    found = glyphs("working", "glyph-working")
    check(bool(found), "working: the glyph-working row shows the working glyph")
    glyph = spinning("glyph-working") or (found[0] if found else None)
    if glyph:
        check_spinner(glyph, "working")
    window = glyph.get("window") if glyph else None
    # The third spinner starts part of a turn later; synced, it shows the others' phase.
    glyphs("working", "glyph-working-2")
    time.sleep(0.37)  # test script: a start offset that is not a whole number of turns
    written = report(working[2] or "", "working", "; sleep 120")
    check(written.returncode == 0, f"working late: the program reports it ({written.stderr.strip()[-120:]})")
    glyphs("working", "glyph-working-late")
    spinning("glyph-working-late")
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    arcs = {(g.get("title") or {}).get("text"): g for w in windows if w.get("window") == window
            for g in w.get("status_glyphs") or [] if g.get("glyph") == "arc"}
    phases = {name: (arcs.get(name) or {}).get("phase") for name in ("glyph-working", "glyph-working-2", "glyph-working-late")}
    print(f"phases: {json.dumps(phases)}", flush=True)
    known = [p for p in phases.values() if p is not None]
    spread = max(min(abs(a - b), 1 - abs(a - b)) for a in known for b in known) if len(known) == 3 else None
    check(spread is not None and spread <= 0.05, f"synced: three spinners, one started later, share one phase (spread {spread})")
    time.sleep(3)  # test script: htop has run at least this long before its check
    htop_glyphs = find_glyphs("glyph-htop")
    check(not htop_glyphs, f"htop: its row shows no status glyph ({json.dumps(htop_glyphs)[:200]})")
    spinning("glyph-working")
    snapshots("glyph-working")
    spinning("glyph-working")
    cpu("three rows working, window shown")
    shown = find_glyphs("glyph-working")
    print(f"after the shown window: animation {(shown[0] if shown else {}).get('animation')}", flush=True)
    time.sleep(3)  # test script: a showMainWindow still in flight would restore the window after the minimize
    action("minimizeWindow")
    stopped = animation_on("glyph-working", window, None)
    if stopped not in (None, "no glyph"):
        action("minimizeWindow")  # once more, after any late restore
        stopped = animation_on("glyph-working", window, None)
    mains = [w for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("kind") == "main"]
    print(f"main windows after the minimize: {json.dumps([(w.get('id'), w.get('visible')) for w in mains])}", flush=True)
    # A minimized window may also drop its rows from the walk ("no glyph"): nothing spins then either.
    check(stopped in (None, "no glyph"), f"minimized: the spinner stops (animation {stopped})")
    cpu("three rows working, window minimized")
    resumed = spinning("glyph-working")
    check(bool(resumed) and resumed.get("animation") == "spin",
          f"shown again: the spinner spins (animation {(resumed or {}).get('animation')})")
    for terminal in (blocked, *working):
        cli("terminal", terminal or "", "write", "--text", "\x03")  # ends the sleep
    cli("terminal", top or "", "write", "--text", "q")  # ends htop
    for terminal in (done, blocked, *working):
        report(terminal or "", "idle")
    print(f"{len(failures)} failure(s)", flush=True)
    sys.exit(1 if failures else 0)

main()
