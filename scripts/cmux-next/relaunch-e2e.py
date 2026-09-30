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

  scripts/cmux-next/relaunch-e2e.py --tag <tag> [--rounds 3] [--modes kill,quit,crash]

Launches the tagged app itself with the brief's no-activate environment and
a scratch CMUX_NEXT_CONFIG_FILE; the tag's app must not be running. Quits
the app it started at the end (the tag's daemon and its terminals stay; stop
them as the brief's cleanup says). Exit 1 on any failed check.
"""
import argparse, glob, json, os, random, re, signal, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--modes", default="kill,quit,crash", help="comma list of kill (SIGKILL), quit (Quit action), crash (debug.crash.app)")
parser.add_argument("--settle", type=float, default=2.0, help="seconds after a workspace switch before checking")
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
        stop(signal.SIGKILL)
        sys.exit("the no-activate app took the keyboard; stopped it (report this as a bug): "
                 f"app_active={focus.get('app_active')} key_window={focus.get('key_window')}")
    print(f"launched pid {app.pid}")


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


LOOP = r"""while :; do printf '\033[3%dmrelaunch-loop %s\033[0m\n' $((RANDOM%8)) $RANDOM; sleep 0.002; done"""
READER = r"""stty -echo; while :; do printf '\033[1;3'; read x; printf 'm got-%s\n' "$x"; done"""


def setup():
    """Two workspaces, five terminals, unless a previous run left them."""
    if any("relaunch-reader" in cli("read-screen", "--surface", s).stdout
           for w in workspaces() for s, _ in surfaces(w)):
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
        return f"{surface} attach phase {view.get('attach')}"
    token = f"tok{TOKENS.randrange(1 << 30)}"
    text = view.get("text") or ""
    if "relaunch-reader" in text or "got-" in text:
        cli("send", "--surface", surface, token + "\n")
        expect = f"got-{token}"
    elif title.startswith("vim"):
        cli("send", "--surface", surface, f"o{token}\x1b")
        expect = token
    elif title.startswith("top") or "relaunch-loop" in text:
        changed = wait(lambda: (mirror(pane_key) or {}).get("text") not in (None, text), 6)
        return None if changed else f"{surface} ({title}) mirror did not change in 6 s"
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


def check_all(label):
    bad = 0
    for workspace in workspaces():
        cli("select-workspace", "--workspace", workspace)
        time.sleep(opts.settle)
        for surface, title in surfaces(workspace):
            problem = check_surface(label, surface, title)
            print(f"  {'BAD' if problem else 'ok '} {label} {workspace} {surface} {title[:30]!r}{': ' + problem if problem else ''}")
            if problem:
                bad += 1
                failures.append(f"{label}: {problem}")
    return bad


def main():
    launch()
    setup()
    check_all("before")
    modes = [m.strip() for m in opts.modes.split(",") if m.strip()]
    step = 0
    for round_index in range(opts.rounds):
        for mode in modes:
            # Alternate the selected workspace: a terminal in a workspace that
            # is not selected at relaunch attaches at a provisional grid on
            # first show and resizes right after its replay.
            refs = workspaces()
            cli("select-workspace", "--workspace", refs[step % len(refs)])
            step += 1
            time.sleep(opts.settle)
            end(mode)
            launch()
            check_all(f"round {round_index + 1} after {mode}")
    stop(signal.SIGTERM)
    print(f"{len(failures)} failed checks; scratch {SCRATCH}")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1 if failures else 0)


try:
    main()
except BaseException:
    stop(signal.SIGTERM)
    raise
