#!/usr/bin/env python3
"""Live check that Cmd-click in a cmux-next terminal is instant (cx-7xss), on a tagged build.

Ghostty reports a Cmd-clicked link (`open_url`) from inside its mouse-release handler with the
terminal's renderer lock held. The app used to open the link right there: a browser tab, or for a
file path a blocking `NSWorkspace.open` that waits for the handler app to launch. The click froze
the main thread and the terminal's output and drawing until the open finished.

The script launches the tagged app itself (no activation, scratch config, empty Ghostty config),
fills a terminal with a link on every row, Cmd-clicks the pane's center through `debug.mouse`
(the real event path: AppKit event, TerminalSurfaceView, libghostty hit testing, `open_url`) and
reads the main-thread watchdog (`debug.hangs`) over the click. Two cases:
  - web URL: a browser tab opens in the pane; no main-thread stall over 50 ms during the click.
  - file path (`--file`): the system opens a .txt, which must show as a TextEdit document (the
    .txt handler on a fresh mini; TextEdit launches); no main-thread stall over 50 ms. Afterwards
    the note is closed, and TextEdit is quit through its quit path only when this run launched it.

On exit it quits the app with quitEndSessions, stops the tag's cmux-tui session and kills any
process left from the tag's bundle by exact PID.

Usage: terminal-cmd-click-e2e.py --tag <tag> --app PATH [--file] [--out DIR]
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app bundle")
parser.add_argument("--file", action="store_true", help="also Cmd-click a file path (launches TextEdit)")
parser.add_argument("--budget-ms", type=float, default=50, help="longest main-thread stall allowed during a click")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
# The bundle's executable (MacOS/ also holds the debug and preview dylibs).
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"cmdclick-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
ROWS = []
# The shell pads each link to exactly two terminal widths (`tput cols`), so every row of the
# screen is a link and the pane's center is always on one.
URL_SHELL = 'c=$(tput cols); t="http://127.0.0.1:9/cx-7xss/"; while [ ${#t} -lt $((2*c)) ]; do t="${t}a"; done'
URL_PREFIX = "http://127.0.0.1:9/cx-7xss/"
NOTE_DIR = os.path.join(SCRATCH, "cx-7xss")
# The note's name pads its path to a multiple of the terminal width (ending in .txt).
NOTE_SHELL = (f'c=$(tput cols); t="{NOTE_DIR}/n"; while [ $(((${{#t}}+4)%c)) -ne 0 ]; do t="${{t}}x"; done; '
              't="$t.txt"; echo cx-7xss > "$t"')
LAUNCHED = []


def run(*args, timeout=30):
    """The bundled CLI against the tagged app (as scripts/cmux-debug-cli.sh sets it up)."""
    env = {**ENV, "CMUX_TAG": TAG, "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
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


def panes():
    return [p for w in (rpc("debug.surfaces", {"text": True}).get("windows") or []) for p in w.get("panes", [])]


def focused_pane():
    return next((p for p in panes() if p.get("focused")), None)


def viewport(pane_key):
    for p in panes():
        if p.get("pane") == pane_key:
            surface = p.get("surface") or {}
            return surface.get("text") or p.get("text") or ""
    return ""


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def textedit_pids():
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    return {int(line.split(None, 1)[0]) for line in ps.splitlines() if "/TextEdit.app/Contents/MacOS/TextEdit" in line}


def textedit(script):
    """AppleScript to TextEdit, only while it runs (asking would launch it)."""
    if not textedit_pids():
        return ""
    return subprocess.run(["osascript", "-e", f'tell application "TextEdit" to {script}'],
                          capture_output=True, text=True, timeout=20).stdout


def note_open():
    """The note is a document of a running TextEdit (the system's .txt handler on a fresh mini)."""
    return "cx-7xss" in textedit("get path of every document")


def click_check(label, pane_key, ref, shell, prefix, opened):
    """Fill every row with the link `shell` sets in $t, Cmd-click the pane's center, read the watchdog."""
    run("terminal", ref, "write", "--text", f"{shell}; clear; for i in $(seq 1 80); do printf '%s\\n' \"$t\"; done\n")
    if not wait(lambda: viewport(pane_key).count(prefix) > 10, 15):
        row(f"{label}: links shown", "the terminal shows the rows", viewport(pane_key)[-200:], False)
        return
    rpc("debug.hangs", {"clear": True})
    rpc("debug.mouse", {"pane": pane_key, "action": "move", "modifiers": ["cmd"]})
    time.sleep(0.3)  # test harness: hover reaches libghostty
    sent = time.time()
    reply = rpc("debug.mouse", {"pane": pane_key, "action": "click", "modifiers": ["cmd"]})
    done = wait(opened, 10, step=0.05)
    elapsed = (time.time() - sent) * 1000
    time.sleep(0.5)  # test harness: let the watchdog see the frames after the open
    hangs = rpc("debug.hangs") or {}
    print(f"--- {label}: debug.mouse {json.dumps(reply)[:300]}", flush=True)
    print(f"debug.hangs {json.dumps({k: v for k, v in hangs.items() if k != 'records'})}", flush=True)
    for record in (hangs.get("records") or [])[-5:]:
        print("hang:", json.dumps(record)[:600], flush=True)
    row(f"{label}: opened", "the link opens", f"opened={bool(done)} after={elapsed:.0f}ms", bool(done))
    longest = hangs.get("max_ms") or 0
    row(f"{label}: main thread", f"no stall over {opts.budget_ms:.0f} ms",
        f"stalls={hangs.get('count')} max={longest:.1f}ms max_gap={hangs.get('max_gap_ms', 0):.1f}ms",
        hangs.get("installed") is not False and longest <= opts.budget_ms)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"cmdclick-{label.replace(' ', '-')}.png")})


app = None


def cleanup():
    print("cleanup", flush=True)
    if os.environ.get("CMDCLICK_E2E_KEEP") or not LAUNCHED:
        return  # never another run's app (the fresh-tag guard exits before launching)
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    for _ in range(2):
        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[2].startswith(APP + "/") and int(parts[0]) != os.getpid():
                print("leftover", line[:160], flush=True)
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(3)  # test harness: let them exit
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app
    if os.path.exists(SOCKET):
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if any(line.startswith(APP + "/Contents/MacOS/") for line in ps.splitlines()):
            sys.exit(f"{SOCKET} exists and a {TAG} app runs; pick a fresh tag")
        os.remove(SOCKET)  # a stale socket of an earlier run of this script
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        print("debug.surfaces:", json.dumps(rpc("debug.surfaces"))[:800], flush=True)
        print("debug.windows:", json.dumps(rpc("debug.windows"))[:800], flush=True)
        sys.exit("the tagged app did not come up")
    # Earlier runs of this script left their workspaces in the tag's state: close them.
    for old in set(re.findall(r"(ws_[0-9a-f]+)\s+cmdclick-e2e", run("workspace", "list").stdout)):
        run("workspace", old, "close")
    made = run("workspace", "create", "--name", "cmdclick-e2e")
    print("workspace create:", (made.stdout + made.stderr)[-400:], flush=True)
    workspace = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
    terminal = re.search(r"value\.terminal_id\s+(term_\S+)", made.stdout)
    tab = re.search(r"value\.tab_id\s+(tab_\S+)", made.stdout)
    if workspace:
        run("workspace", workspace.group(1), "focus")
    # The mux focus does not move the Mac window off Home: select the window's workspaces by
    # number until the new one (its tab) shows.
    for index in range(1, 10):
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        if wait(lambda: any(tab and p.get("selected_tab") == tab.group(1) for p in panes()), 3):
            print("new workspace is number", index, flush=True)
            break
    if not wait(lambda: (focused_pane() or {}).get("kind") == "terminal", 30):
        print("panes:", json.dumps(panes())[:1500], flush=True)
    time.sleep(2)  # test harness: shell prompt
    pane = focused_pane() or {}
    if pane.get("kind") != "terminal" or not terminal:
        row("setup", "a focused terminal", f"focused={pane.get('kind')}", False)
        return
    pane_key, ref, term_tab = pane["pane"], terminal.group(1), pane.get("selected_tab")
    print("terminal tab", term_tab, flush=True)

    def tab_opened():
        now = next((p for p in panes() if p.get("pane") == pane_key), {})
        return now.get("selected_tab") not in (None, term_tab)

    click_check("web URL", pane_key, ref, URL_SHELL, URL_PREFIX, tab_opened)
    if not opts.file:
        return
    # Back to the terminal tab for the file case.
    rpc("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": term_tab}})
    if not wait(lambda: (focused_pane() or {}).get("selected_tab") == term_tab, 10):
        row("file path: back to the terminal", term_tab, (focused_pane() or {}).get("selected_tab"), False)
        return
    os.makedirs(NOTE_DIR, exist_ok=True)
    before = textedit_pids()
    if note_open():
        row("file path: setup", "the note is not open yet", "TextEdit already shows it", False)
        return
    try:
        click_check("file path", pane_key, ref, NOTE_SHELL, NOTE_DIR, note_open)
    finally:
        # Only what this run opened: its note, or TextEdit when this run launched it.
        textedit('close (every document whose path contains "cx-7xss") saving no')
        if not before and textedit_pids():
            textedit("quit saving no")


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
