#!/usr/bin/env python3
"""New terminals start where the user is (NEW-TERMINAL-INHERITS-CWD), live on a tagged build.

Launches the tagged app (no-activate, automation socket, scratch cmux.json and Ghostty config),
makes a workspace, `cd`s its terminal into a scratch folder, then opens a new terminal through
each entry point and reads `pwd` from the new terminal's screen:

  cmd-t        Cmd-T with tabs.newTabKind = terminal (a key event, origin user)
  page         Cmd-T on the default New Tab page, then `!` (the page's terminal choice)
  palette      New Terminal Tab (`newSurface`) as the palette runs it (origin user)
  split        Split Right (`splitRight`, origin user)
  cli-tab      `cmux new-surface` without --cwd (origin cli)
  cli-split    `cmux new-split right` without --cwd (origin cli)

With `--ghostty 'window-inherit-working-directory = false'` (and an optional
`working-directory = <dir>`), every entry point must start in the fallback instead.

Run on cmux-lawrence-2 or a fleet Mac, never on the laptop. Exit 1 on any failed check.
Usage: terminal-cwd-live.py --tag <tag> [--app <bundle>] [--ghostty '<line>'...] [--expect inherit|fallback]
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--ghostty", action="append", default=[], help="a line for the scratch Ghostty config")
parser.add_argument("--expect", choices=["inherit", "fallback"], default="inherit")
parser.add_argument("--fallback", help="the folder expected with --expect fallback (default: $HOME)")
parser.add_argument("--only", default="", help="comma list of entry points to run (default: all)")
opts = parser.parse_args()

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
# A short path: the daemon's grid is 80 columns, and a wrapped path is harder to read back.
SCRATCH = os.path.realpath(tempfile.mkdtemp(prefix="twd", dir="/tmp"))
WORK = os.path.join(SCRATCH, "p d")  # a space: the path survives quoting
os.makedirs(WORK)
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
EXPECTED = WORK if opts.expect == "inherit" else os.path.realpath(opts.fallback or os.environ["HOME"])
failures, results = [], {}
app = None


def daemon_socket():
    """The tag's cmux-tui session socket (`cmux-app-<tag>`), as bench-startup.py finds it."""
    roots = {os.environ.get("TMPDIR", "/tmp"), BASE_ENV["TMPDIR"], "/tmp"}
    # The app's own TMPDIR when the job runner sets another one.
    darwin_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    if darwin_tmp:
        roots.add(darwin_tmp)
    for root in roots:
        found = glob.glob(os.path.join(root, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))
        if found:
            return found[0]
    return None


def cli(*args, timeout=30):
    sock = daemon_socket()
    target = ["--socket", sock] if sock else ["--app-socket", SOCKET]
    return subprocess.run([CLI, *target, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def cli_json(*args):
    r = cli("--json", *args)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def rpc(method, params=None, timeout=30):
    """One request line on the app control socket (`{"id","method","params"}`)."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCKET)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def rows(value):
    """The list of resource rows in a `--json ... list` reply."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for k in ("items", "terminals", "panes", "tabs", "result", "data"):
            if isinstance(value.get(k), list):
                return value[k]
    return []


def terminals():
    """terminal id -> row, for every running terminal the daemon lists."""
    return {row["id"]: row for row in rows(cli_json("terminal", "list")) if isinstance(row, dict) and row.get("id")}


def pane_of(terminal):
    """The pane that shows `terminal` (through its first tab)."""
    tab_ids = (terminals().get(terminal) or {}).get("tab_ids") or []
    for row in rows(cli_json("tab", "list")):
        if isinstance(row, dict) and row.get("id") in tab_ids:
            return row.get("pane_id") or row.get("pane")
    return None


def screen_pwd(terminal, token):
    """Types a marker command into `terminal` and reads the folder it prints."""
    cli("terminal", terminal, "write", "--text", f"printf 'TWD{token}=%s\\n' \"$PWD\"\n")
    pattern = re.compile(rf"TWD{token}=(/.*)$", re.M)

    def read():
        m = pattern.search(cli("terminal", terminal, "screen", "read").stdout.replace("\\n", "\n"))
        return m and m.group(1).rstrip()
    return wait(read, 15)


def launch(config):
    global app
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    cfg = os.path.join(SCRATCH, "cmux.json")
    ghostty = os.path.join(SCRATCH, "ghostty")
    with open(cfg, "w") as f:
        json.dump(config, f)
    with open(ghostty, "w") as f:
        f.write("".join(line + "\n" for line in opts.ghostty))
    env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": cfg,
           "CMUX_NEXT_GHOSTTY_CONFIG": ghostty, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    log = open(os.path.join(SCRATCH, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    up = wait(lambda: os.path.exists(SOCKET) and "windows" in rpc("debug.surfaces"), 180, 0.5)
    if up and not rpc("debug.surfaces").get("windows"):
        # A fresh tag can come up without a main window; open one as the menu does.
        print(f"no window at launch; newWindow: {rpc('action.run', {'action': 'newWindow', 'origin': 'script', 'focus': True})}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 60, 0.5):
        log.flush()
        tail = open(os.path.join(SCRATCH, "app.log"), errors="replace").read()[-4000:]
        sys.exit(f"tagged app did not come up (exit {app.poll()}, socket {os.path.exists(SOCKET)}, "
                 f"reply {rpc('debug.surfaces')}); log tail:\n{tail}")
    print(f"launched pid {app.pid}", flush=True)


def quit_app():
    if app and app.poll() is None:
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGKILL)  # the exact PID this script started
            app.wait()


def source_terminal():
    """A fresh workspace whose terminal is focused and has `cd`ed into WORK."""
    before = set(terminals())
    made = rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    new = wait(lambda: sorted(set(terminals()) - before), 30)
    if not new:
        listing = cli("--json", "terminal", "list")
        failures.append(f"no source terminal after workspace new: {made}; terminal list: "
                        f"{(listing.stdout + listing.stderr)[:1500]}")
        return None
    surface = new[0]
    cli("terminal", surface, "write", "--text", f"cd '{WORK}'\n")
    if screen_pwd(surface, "src") != WORK:
        screen = cli("terminal", surface, "screen", "read")
        failures.append(f"source terminal {surface} did not reach {WORK}; screen: "
                        f"{(screen.stdout + screen.stderr)[-1500:]}")
        return None
    time.sleep(1)  # let the shell's OSC 7 report reach the daemon (harness wait)
    return surface


def check(name, trigger):
    if opts.only and name not in opts.only.split(","):
        return
    source = source_terminal()
    if not source:
        return
    before = set(terminals())
    reply = trigger(source)
    new = wait(lambda: sorted(set(terminals()) - before), 30)
    if not new:
        failures.append(f"{name}: no new terminal ({str(reply)[:300]})")
        results[name] = None
        return
    got = screen_pwd(new[0], name.replace("-", ""))
    results[name] = got
    ok = got == EXPECTED
    print(f"{'ok  ' if ok else 'FAIL'} {name}: pwd {got!r} (expected {EXPECTED!r})", flush=True)
    if not ok:
        failures.append(f"{name}: {got!r} != {EXPECTED!r}")


def key(k, mods=None):
    return rpc("debug.key", {"key": k, "modifiers": mods or []})


def page_terminal(_source):
    key("t", ["cmd"])
    time.sleep(1.5)  # the page loads (harness wait)
    key("!")


teardown = TagTeardown(APP)
teardown.install()
try:
    # Cmd-T opens a terminal directly in this run.
    launch({"tabs": {"newTabKind": "terminal"}})
    check("cmd-t", lambda _s: key("t", ["cmd"]))
    check("palette", lambda s: rpc("action.run", {"action": "newSurface", "origin": "script", "focus": True}))
    check("split", lambda s: rpc("action.run", {"action": "splitRight", "origin": "script", "focus": True}))
    check("cli-tab", lambda s: cli("tab", "create", "terminal", "--pane", pane_of(s) or "-"))
    check("cli-split", lambda s: cli("pane", pane_of(s) or "-", "split", "--right"))
    quit_app()
    # The default New Tab page, then its terminal choice.
    if not opts.only or "page" in opts.only.split(","):
        launch({})
        check("page", page_terminal)
        quit_app()
finally:
    quit_app()
    teardown.end()
    print(json.dumps({"expected": EXPECTED, "results": results, "failures": failures}, indent=1), flush=True)
sys.exit(1 if failures else 0)
