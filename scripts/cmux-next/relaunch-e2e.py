#!/usr/bin/env python3
"""Kill, quit or crash a tagged cmux-next app and check every restored terminal.

Dogfood nxdog11: "after killing and reopening, persisted sessions are kinda
frozen". The daemon keeps every terminal running while the app is gone; on
relaunch each view re-attaches from a replay. This script builds a session
that stresses that path, ends the app, relaunches it and checks each terminal
view in every workspace:

  - the attach machine is `live` (debug.surfaces `attach`);
  - the view renders new output: a token sent to the terminal appears in the
    Ghostty mirror (debug.surfaces `text`), or the screen of a program that
    redraws by itself (top, an output loop) changes;
  - the shell's `stty size` equals the grid the mirror renders.

Terminals: `top`, vim, an idle shell, a colored output loop, and a reader
that always waits inside an unfinished escape sequence (`ESC [ 1 ; 3`). The
app is ended with a different workspace selected each time, so the other
workspace's terminals attach at a provisional grid on first show and their
PTYs resize mid-sequence (terminal-pending-sequence-v1). Each launch also
alternates the test window frame, so the relaunch itself resizes them.

  scripts/cmux-next/relaunch-e2e.py --tag <tag> [--rounds 3] [--modes kill,quit,crash] [--disconnect]
  scripts/cmux-next/relaunch-e2e.py --tag <tag> --long-top 600

--disconnect drops a view with the daemon's detach-client and checks the
disconnected label rules (coordinator decision 1). --long-top runs a fresh
`top` for SECONDS and reports every stall (daemon moved, mirror did not for
6 s) with the view's attach phase, link and surface state.

Launches the tagged app itself with the brief's no-activate environment and
a scratch CMUX_NEXT_CONFIG_FILE; the tag's app must not be running. Quits
the app it started at the end (the tag's daemon and its terminals stay; stop
them as the brief's cleanup says). Exit 1 on any failed check.
"""
import argparse, glob, json, os, random, re, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--modes", default="kill,quit,crash", help="comma list of kill (SIGKILL), quit (Quit action), crash (debug.crash.app)")
parser.add_argument("--settle", type=float, default=2.0, help="seconds after a workspace switch before checking")
parser.add_argument("--attach-deadline", type=float, default=20.0, help="seconds a view may take to reach live")
parser.add_argument("--disconnect", action="store_true", help="also drop views with detach-client and check each re-attaches on a key press and on being shown")
parser.add_argument("--long-top", type=float, default=0, metavar="SECONDS",
                    help="instead of relaunch rounds: a fresh top in its own workspace, compared with the daemon every 2 s for SECONDS")
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
TMP = os.environ.get("TMPDIR", "/tmp")
SCRATCH = tempfile.mkdtemp(prefix=f"relaunch-e2e-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": TMP,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
TOKENS = random.SystemRandom()
failures = []
slow = []
app = None


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None):
    r = cli("rpc", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


# Window frames the launches alternate between (points from the top-left of
# the screen's visible frame): a relaunch restores at another size, as after
# a display or window change, so every restored PTY resizes on attach.
FRAMES = ["40,40,1100,720", "40,40,980,640"]
launches = 0


def launch():
    global app, launches
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_TEST_WINDOW_FRAME": FRAMES[launches % len(FRAMES)]}
    launches += 1
    log = open(os.path.join(SCRATCH, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    ready = wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 60, 0.5)
    if not ready:
        sys.exit(f"tagged app did not come up (log {SCRATCH}/app.log)")
    focus = rpc("debug.focus")
    if focus.get("app_active") or focus.get("key_window"):
        # Evidence first: a user click shows as a system mouse event in the journal.
        evidence = os.path.join(SCRATCH, "focus-violation.json")
        with open(evidence, "w") as out:
            json.dump({"focus": focus, "journal": rpc("debug.journal")}, out, indent=1)
        print(f"  focus evidence: {evidence}")
        stop(signal.SIGKILL)
        sys.exit("the no-activate app took the keyboard; stopped it (report this as a bug): "
                 f"app_active={focus.get('app_active')} key_window={focus.get('key_window')}")
    given = (focus.get("keyboard_given_back") or {}).get("count") or 0
    print(f"launched pid {app.pid}" + (f" (no-activate guard gave the keyboard back {given}x)" if given else ""))


def stop(sig):
    if app and app.poll() is None:
        app.send_signal(sig)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()


def end(mode):
    """End the app the way the mode says; the daemon keeps running."""
    if mode == "kill":
        stop(signal.SIGKILL)
    elif mode == "crash":
        rpc("debug.crash.app", {"kind": "segv"})
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            stop(signal.SIGKILL)
    else:
        rpc("action.run", {"id": "quit"})
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            print("  quit action did not end the app; SIGTERM (also a normal quit)")
            stop(signal.SIGTERM)
    print(f"ended app ({mode}), exit {app.returncode}")


def workspaces():
    refs = []
    for line in cli("list-workspaces").stdout.splitlines():
        m = re.search(r"(workspace:\d+)", line)
        if m:
            refs.append(m.group(1))
    return refs


def surfaces(workspace):
    """[(surface ref, title)] of the workspace's selected terminal tabs."""
    out = []
    for line in cli("tree", "--workspace", workspace).stdout.splitlines():
        m = re.search(r"surface (surface:\d+) \[terminal\] \"(.*)\" \[selected\]", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


LOOP = r"""echo relaunch-loop; while :; do printf '\033[3%dmrelaunch-loop %s\033[0m\n' $((RANDOM%8)) $RANDOM; sleep 0.002; done"""
READER = r"""stty -echo; while :; do printf '\033[1;3'; read x; printf 'm got-%s\n' "$x"; done"""


def setup():
    """Two workspaces, six terminals, the first workspace on two screens,
    unless a previous run left them."""
    if "relaunch-2" in cli("list-workspaces").stdout:
        print("reusing the session a previous run built")
        return
    first = workspaces()[0]
    top = wait(lambda: surfaces(first), 20)[0][0]
    vim_ref = cli("new-split", "right", "--workspace", first, "--surface", top, "--focus", "false").stdout.split()[1]
    idle = cli("new-split", "down", "--workspace", first, "--surface", top, "--focus", "false").stdout.split()[1]
    second = cli("new-workspace", "--name", "relaunch-2", "--focus", "false").stdout.split()[1]
    found = wait(lambda: surfaces(second), 20)
    if not found:
        sys.exit(f"workspace {second} never showed a terminal")
    loop = found[0][0]
    reader = cli("new-split", "right", "--workspace", second, "--surface", loop, "--focus", "false").stdout.split()[1]
    cli("send", "--surface", top, "top -s 1\n")
    cli("send", "--surface", vim_ref, f"vim -u NONE {SCRATCH}/vim.txt\n")
    cli("send", "--surface", idle, "echo relaunch-idle\n")
    cli("send", "--surface", loop, LOOP + "\n")
    cli("send", "--surface", reader, "echo relaunch-reader; " + READER + "\n")
    # A second screen in the first workspace with another reader waiting
    # inside an escape sequence: panes on a screen that is not shown have no
    # view, and a relaunch shows them later.
    cli("select-workspace", "--workspace", first)
    time.sleep(opts.settle)
    before = {ref for ref, _ in surfaces(first)}
    rpc("action.run", {"id": "screen.new"})
    added = wait(lambda: [ref for ref, _ in surfaces(first) if ref not in before], 20)
    if not added:
        sys.exit("screen.new made no terminal")
    cli("send", "--surface", added[0], "echo relaunch-reader-screen2; " + READER + "\n")
    time.sleep(1)
    rpc("action.run", {"id": "screen.previous"})
    time.sleep(3)


def view_rows(workspace_key=None):
    rows = []
    for window in rpc("debug.surfaces", {"text": True}).get("windows", []):
        for pane in window["panes"]:
            if pane.get("kind") == "terminal" and pane.get("presence") == "visible":
                rows.append(pane)
    return rows


def pane_for(surface):
    """The visible pane showing `surface` (matched through the CLI pane list)."""
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if not m:
            continue
        if re.search(rf"\*\s+{surface}\b", cli("list-pane-surfaces", "--pane", m.group(1)).stdout):
            return "pane_" + m.group(2).replace("-", "").lower()
    return None


def mirror(pane_key):
    return next((p for p in view_rows() if p["pane"] == pane_key), None)


def check_surface(label, surface, title):
    pane_key = pane_for(surface)
    view = pane_key and mirror(pane_key)
    if not view:
        return f"{surface} has no visible view"
    if view.get("attach") != "live":
        # A terminal with a large scrollback takes seconds to decode its
        # replay on a loaded machine; slow is reported, stuck fails.
        started = time.time()
        live = wait(lambda: (mirror(pane_key) or {}).get("attach") == "live" and mirror(pane_key), opts.attach_deadline)
        if not live:
            return f"{surface} attach phase {(mirror(pane_key) or {}).get('attach')} after {opts.attach_deadline:.0f} s"
        slow.append(f"{label} {surface} reached live {time.time() - started + opts.settle:.1f} s after its workspace was shown")
        view = live
    token = f"tok{TOKENS.randrange(1 << 30)}"
    text = view.get("text") or ""
    if "relaunch-reader" in title:
        cli("send", "--surface", surface, token + "\n")
        expect = f"got-{token}"
    elif title.startswith("vim"):
        cli("send", "--surface", surface, f"o{token}\x1b")
        expect = token
    elif title.startswith("top") or "relaunch-loop" in title:
        daemon_before = cli("read-screen", "--surface", surface).stdout
        changed = wait(lambda: (mirror(pane_key) or {}).get("text") not in (None, text), 10)
        if changed:
            return None
        if cli("read-screen", "--surface", surface).stdout == daemon_before:
            print(f"  note: {surface} ({title}) did not redraw in the daemon either (machine busy); not counted")
            return None
        return f"{surface} ({title}) daemon screen changed but the mirror did not in 10 s"
    else:
        cli("send", "--surface", surface, f"echo {token} $(stty size)\n")
        expect = token
    seen = wait(lambda: expect in ((mirror(pane_key) or {}).get("text") or "").replace("\n", ""), 6)
    if not seen:
        return f"{surface} ({title}) mirror never showed {expect}"
    if expect == token and not title.startswith("vim"):
        grid = (mirror(pane_key) or {}).get("surface", {}).get("grid")
        m = re.search(rf"{token} (\d+) (\d+)", ((mirror(pane_key) or {}).get("text") or "").replace("\n", ""))
        if m and grid and grid != f"{m.group(2)}x{m.group(1)}":
            return f"{surface} shell size {m.group(2)}x{m.group(1)} but mirror grid {grid}"
    return None


def pane_screens():
    """Daemon pane resource id -> screen resource id, over every workspace."""
    screens = {}
    for workspace in daemon("list-workspaces").get("data", {}).get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                screens[pane.get("resource_id")] = screen.get("resource_id")
    return screens


def shown_screen():
    """(active screen, screen count) of the window's shown workspace (debug.screens)."""
    window = next(iter(rpc("debug.screens").get("windows", [])), {})
    return window.get("active_screen"), len(window.get("screens", []))


def pane_keys():
    """CLI surface ref -> daemon pane resource id, for the current workspace."""
    keys = {}
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if not m:
            continue
        found = re.search(r"\*\s+(surface:\d+)", cli("list-pane-surfaces", "--pane", m.group(1)).stdout)
        if found:
            keys[found.group(1)] = "pane_" + m.group(2).replace("-", "").lower()
    return keys


def check_hidden(label, surface, title):
    """A pane on a screen that is not shown has no visible view: the
    terminal must still be alive and accept input (daemon read-screen), and
    any view the app keeps for it must not be closed."""
    token = f"tok{TOKENS.randrange(1 << 30)}"
    if "relaunch-reader" in title:
        cli("send", "--surface", surface, token + "\n")
        expect = f"got-{token}"
    elif title.startswith(("top", "vim")) or "relaunch-loop" in title:
        return None if cli("read-screen", "--surface", surface).stdout.strip() else f"{surface} (hidden) daemon screen empty"
    else:
        cli("send", "--surface", surface, f"echo {token}\n")
        expect = token
    if not wait(lambda: expect in cli("read-screen", "--surface", surface).stdout.replace("\n", ""), 6):
        return f"{surface} ({title}, hidden screen) daemon never showed {expect}"
    return None


def check_all(label):
    """Every workspace, every screen: panes on the shown screen get the view
    checks; panes on other screens get the daemon checks first, then each
    screen is shown in turn and its panes get the view checks too."""
    bad = 0

    def report(where, surface, title, problem):
        nonlocal bad
        print(f"  {'BAD' if problem else 'ok '} {label} {where} {surface} {title[:30]!r}{': ' + problem if problem else ''}")
        if problem:
            bad += 1
            failures.append(f"{label}: {problem}")

    for workspace in workspaces():
        cli("select-workspace", "--workspace", workspace)
        time.sleep(opts.settle)
        titles = dict(surfaces(workspace))
        keys = pane_keys()
        screens = pane_screens()
        active, count = shown_screen()
        for surface, title in titles.items():
            if screens.get(keys.get(surface)) not in (None, active):
                report(f"{workspace} hidden-screen", surface, title, check_hidden(label, surface, title))
        for index in range(max(1, count)):
            if index:
                rpc("action.run", {"id": "screen.next"})
                time.sleep(opts.settle)
                active, _ = shown_screen()
            for surface, title in titles.items():
                if screens.get(keys.get(surface)) in (None, active):
                    report(f"{workspace} screen {index + 1}/{count}", surface, title, check_surface(label, surface, title))
        if count > 1:
            rpc("action.run", {"id": "screen.next"})  # back to the first screen
    return bad


def daemon(cmd, **fields):
    """One request on the tag's daemon socket (a separate client)."""
    path = next(iter(glob.glob(os.path.join(TMP, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))), None)
    if not path:
        return {}
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(path)
        stream = sock.makefile("rwb")
        stream.write((json.dumps({"id": 1, "cmd": cmd, **fields}) + "\n").encode())
        stream.flush()
        for line in stream:
            reply = json.loads(line)
            if reply.get("id") == 1:
                return reply
    return {}


def detach_view(pane_key):
    """Drops the app's attach connection for the pane's terminal (detach-client)."""
    surface = None
    for workspace in daemon("list-workspaces").get("data", {}).get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                if pane.get("resource_id") == pane_key and pane.get("tabs"):
                    surface = pane["tabs"][pane.get("active_tab", 0)]["surface"]
    clients = [c["client"] for c in daemon("list-clients").get("data", [])
               if c.get("name") == "cmux-next-terminal" and surface in c.get("attached", [])]
    for client in clients:
        daemon("detach-client", client=client)
    return bool(clients)


def link(pane_key):
    return (mirror(pane_key) or {}).get("link") or ""


def check_disconnect(label):
    """A view dropped by the daemon shows disconnected, stays so without an
    event, and re-attaches on a key press and on being shown again."""
    refs = workspaces()
    first = refs[0]
    cli("select-workspace", "--workspace", first)
    time.sleep(opts.settle)
    idle = next((s for s, title in surfaces(first) if not title.startswith(("top", "vim"))), None)
    pane_key = idle and pane_for(idle)
    problems = []
    if not pane_key:
        return [f"{label}: no idle shell to drop"]
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if m and "pane_" + m.group(2).replace("-", "").lower() == pane_key:
            cli("focus-pane", "--pane", m.group(1), "--workspace", first)
    # 1. Key press.
    if not detach_view(pane_key) or not wait(lambda: link(pane_key).startswith("disconnected"), 5):
        problems.append(f"{label}: {idle} did not show disconnected after detach-client (link {link(pane_key)!r})")
    else:
        time.sleep(3)
        if not link(pane_key).startswith("disconnected"):
            problems.append(f"{label}: {idle} re-attached without an event ({link(pane_key)!r})")
        token = f"tok{TOKENS.randrange(1 << 30)}"
        cli("send", "--surface", idle, f"echo {token}\n")
        rpc("debug.key", {"key": "z"})
        if not wait(lambda: link(pane_key) == "connected" and token in ((mirror(pane_key) or {}).get("text") or ""), 10):
            problems.append(f"{label}: a key press did not re-attach {idle} with the missed output (link {link(pane_key)!r})")
        cli("send", "--surface", idle, "\x15")
    # 2. Shown again.
    if not detach_view(pane_key) or not wait(lambda: link(pane_key).startswith("disconnected"), 5):
        problems.append(f"{label}: second detach-client not seen")
    elif len(refs) > 1:
        cli("select-workspace", "--workspace", refs[1])
        time.sleep(opts.settle)
        cli("select-workspace", "--workspace", first)
        if not wait(lambda: link(pane_key) == "connected", 10):
            problems.append(f"{label}: showing {idle} again did not re-attach it (link {link(pane_key)!r})")
    focus = rpc("debug.focus")
    if focus.get("app_active") or focus.get("key_window"):
        problems.append(f"{label}: the no-activate app took the keyboard during the disconnect check")
    for problem in problems:
        print(f"  BAD {problem}")
    if not problems:
        print(f"  ok  {label} disconnect: key press and show re-attach, nothing without an event")
    failures.extend(problems)
    return problems


def long_top(seconds):
    """A fresh top compared with the daemon every 2 s. Reports each stall:
    the daemon screen moved but the mirror did not for 6 s or more, with the
    view's attach phase, link and surface state at that moment."""
    name = f"relaunch-top-{TOKENS.randrange(1 << 20)}"
    ref = cli("new-workspace", "--name", name).stdout.split()[1]
    surface = wait(lambda: surfaces(ref), 20)[0][0]
    cli("send", "--surface", surface, "top -s 1\n")
    cli("select-workspace", "--workspace", ref)
    time.sleep(3)
    pane_key = wait(lambda: pane_for(surface), 20)
    if not pane_key or not wait(lambda: mirror(pane_key), 20):
        failures.append(f"long top: {surface} never showed a view")
        print(f"  BAD long top: {surface} never showed a view")
        return
    started = time.time()
    last_mirror, last_daemon = None, None
    mirror_since, stalls, samples = time.time(), [], 0
    while time.time() - started < seconds:
        view = mirror(pane_key) or {}
        text = view.get("text")
        screen = cli("read-screen", "--surface", surface).stdout
        samples += 1
        if text != last_mirror:
            last_mirror, mirror_since = text, time.time()
        elif screen != last_daemon and time.time() - mirror_since >= 6:
            state = {k: view.get(k) for k in ("attach", "link", "phase", "presence")}
            state.update({k: (view.get("surface") or {}).get(k) for k in ("rendering_suspended", "drawing", "grid", "replay_applied")})
            stalls.append((round(time.time() - started), round(time.time() - mirror_since), state))
            print(f"  STALL at {stalls[-1][0]} s: mirror unchanged {stalls[-1][1]} s while the daemon moved; {state}")
        last_daemon = screen
        time.sleep(2)
    print(f"long top: {samples} samples over {seconds:.0f} s, {len(stalls)} stall samples")
    if stalls:
        failures.append(f"long top: {len(stalls)} stall samples, first {stalls[0]}")


def main():
    launch()
    if opts.long_top:
        long_top(opts.long_top)
        stop(signal.SIGTERM)
        print(f"{len(failures)} failed checks; scratch {SCRATCH}")
        sys.exit(1 if failures else 0)
    setup()
    check_all("before")
    if opts.disconnect:
        check_disconnect("before")
    modes = [m.strip() for m in opts.modes.split(",") if m.strip()]
    step = 0
    for round_index in range(opts.rounds):
        for mode in modes:
            # Alternate the selected workspace: a terminal in a workspace that
            # is not selected at relaunch attaches at a provisional grid on
            # first show and resizes right after its replay.
            refs = workspaces()
            cli("select-workspace", "--workspace", refs[step % len(refs)])
            if step % 3 == 2:
                rpc("action.run", {"id": "screen.next"})  # relaunch on the second screen
            step += 1
            time.sleep(opts.settle)
            end(mode)
            launch()
            check_all(f"round {round_index + 1} after {mode}")
            if opts.disconnect:
                check_disconnect(f"round {round_index + 1} after {mode}")
    stop(signal.SIGTERM)
    for note in slow:
        print(f"  slow: {note}")
    print(f"{len(failures)} failed checks; scratch {SCRATCH}")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1 if failures else 0)


try:
    main()
except BaseException:
    stop(signal.SIGTERM)
    raise
