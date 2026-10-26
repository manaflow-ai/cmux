#!/usr/bin/env python3
"""Live check: Cmd-hover and Cmd-click on links in a terminal, as a mouse does.

  scripts/cmux-next/terminal-cmd-click-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (no activation, automation socket) as a recording build
(`CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1`) with links routed to the default browser, so a
link click is recorded (`system:<url>`), not opened. `debug.terminal.links` moves the
pointer, presses modifier keys and clicks through the terminal view's own mouse and key
handlers. Checks, in a plain shell:

  1. Command pressed with the pointer still on a URL, then a click: the link opens (the
     first cell the pointer reached; Ghostty used to look only after another cell);
  2. the same in a terminal without focus (it gets no key events);
  3. Shift-Command on a URL opens it (Ghostty matched Command alone);
  4. a URL the shell soft-wrapped opens whole from its second row;

and in a full-screen program that reads the mouse (a fixture TUI, as Claude Code or Codex):

  5. Cmd-hover on a URL underlines it with the pointing hand;
  6. Cmd-click opens it and the program sees no press; a plain click still reaches it;
  7. an OSC 8 hyperlink opens its target;
  8. a URL the program broke onto two rows itself opens whole from either row, and the
     hover reports the whole URL;
  9. `src/app.ts:3:5` opens the code editor at line 3, column 5;

and, with --agent codex=PATH / claude=PATH, in real Codex or Claude Code:

 10. a long URL the agent printed, on several rows, shows whole with the hand and every row
     underlined, and a Cmd-click on its first or last row opens it whole;
 11. a path:line the agent printed opens the file at that line.

Window snapshots go to --out. GUI host only (a capture mini). Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, re, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="terminal-cmd-click-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--agent", action="append", default=[],
                    help="KIND=PATH (codex or claude, repeatable): also run that real agent CLI, which prints a long URL and a path")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []
report = {"tag": opts.tag, "checks": [], "snapshots": []}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    report["checks"].append({"ok": bool(ok), "what": what})
    if not ok:
        failures.append(what)
    return ok


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
    result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result if isinstance(result, dict) else {"value": result}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    check(bool(value), what)
    return value


TERMINAL = None


def links(**params):
    return rpc("debug.terminal.links", {"tab": TERMINAL, **params})


def settle():
    time.sleep(0.6)  # test harness: a file check's answer lands off the main thread


def hover(column, row, keys=("command",)):
    links(hover=[column, row], keys=list(keys))
    settle()
    return links()


def click(column, row, keys=("command",)):
    links(clear=True)
    links(click=[column, row], keys=list(keys))
    time.sleep(1.5)  # test harness: the open runs after the click returns, off the main thread
    return links().get("opened") or []


SHOTS = []


def snapshot(name):
    """A window snapshot, numbered in the order taken (the frames of the run's video)."""
    SHOTS.append(name)
    path = os.path.join(opts.out, f"{len(SHOTS):02d}-{name}.png")
    windows = rpc("debug.window_list").get("windows") or []
    params = {"path": path}
    if windows:
        params["window"] = windows[0].get("id")
    rpc("debug.window_snapshot", params, timeout=60)
    report["snapshots"].append({"name": name, "path": path, "exists": os.path.exists(path)})


def send(text):
    rpc("action.run", {"action": "terminal.sendText", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script",
                       "args": {"text": text}})


REPO = os.path.realpath(tempfile.mkdtemp(prefix="cmdclick-repo-"))
for folder in (".git", "src", "sub"):
    os.makedirs(os.path.join(REPO, folder), exist_ok=True)
with open(os.path.join(REPO, "src", "app.ts"), "w") as f:
    f.write("const a = 1;\nconst b = 2;\nconst c = 3;\n")

# The fixture TUI: alternate screen, mouse reporting (1000/1002/1006), and its own line
# breaks, as Claude Code and Codex draw. It writes where it drew each link and logs every
# byte it reads (mouse reports included).
TUI = os.path.join(REPO, "tui.py")
LAYOUT = os.path.join(REPO, "layout.json")
TUI_LOG = os.path.join(REPO, "tui.log")
LONG_URL = "https://example.com/wrapped/" + "segment-" * 30 + "end?x=1"
with open(TUI, "w") as f:
    f.write(r'''
import json, os, sys, termios, tty
layout_path, log_path, long_url = sys.argv[1], sys.argv[2], sys.argv[3]
cols, rows = os.get_terminal_size()
out = sys.stdout
def at(row, col, text):
    out.write(f"\x1b[{row + 1};{col + 1}H{text}")
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
out.write("\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[2J")
at(0, 0, "fixture TUI: mouse reporting on, its own line breaks")
at(2, 2, "Plain: https://example.com/tui-plain")
at(4, 2, "OSC 8: \x1b]8;;https://example.com/osc8-target\x1b\\open the docs\x1b]8;;\x1b\\")
width = cols - 2
pieces = [long_url[i:i + width] for i in range(0, len(long_url), width)]
for index, piece in enumerate(pieces):
    at(6 + index, 2, piece)
path_row = 6 + len(pieces) + 1
at(path_row, 2, "Edited src/app.ts:3:5")
at(path_row + 2, 2, "plain text")
out.flush()
with open(layout_path, "w") as f:
    json.dump({"cols": cols, "plain": [12, 2], "osc8": [12, 4], "wrapped": [[4, 6], [4, 7]],
               "wrappedRows": len(pieces), "path": [12, path_row], "text": [4, path_row + 2]}, f)
with open(log_path, "ab", buffering=0) as log:
    while True:
        data = os.read(fd, 1024)
        if not data or data == b"q":
            break
        log.write(data)
out.write("\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?1049l")
out.flush()
termios.tcsetattr(fd, termios.TCSADRAIN, saved)
''')


def presses():
    """Left-button presses and releases the TUI read (SGR `ESC [ < 0 ; x ; y M|m`)."""
    try:
        data = open(TUI_LOG, "rb").read().decode("latin-1")
    except OSError:
        return 0
    return len(re.findall(r"\x1b\[<0;\d+;\d+[Mm]", data))


def agent_url(kind):
    return f"https://example.com/{kind}-check/" + "-".join(f"part{i:02d}" for i in range(24)) + f"/end?{kind}=1"


def viewport_rows(marker):
    """The rows of the terminal viewport that shows `marker` (debug.surfaces text)."""
    for window in rpc("debug.surfaces", {"text": True}).get("windows") or []:
        for pane in window.get("panes") or []:
            text = pane.get("text") or ""
            if marker in text:
                return text.split("\n")
    return None


AGENT_NAMES = {"codex": "Codex", "claude": "Claude Code"}


def run_agent(kind, path):
    """A real agent prints a long URL and a path; Command over each shows and opens it."""
    name, url, marker = AGENT_NAMES[kind], agent_url(kind), f"{kind}=1"
    links(modifiers=[])
    prompt = f"Reply with exactly these two lines and nothing else. Line 1: {url} Line 2: Edited src/app.ts:3:5"
    flags = "-a never -s read-only" if kind == "codex" else "--permission-mode plan"
    send(f"clear && cd {REPO} && {path} {flags} '{prompt}'\n")
    if kind == "claude":
        # A new folder asks whether to trust it: Down to "Yes, I trust this folder", then Return, as keys.
        if quiet_wait(lambda: viewport_rows("trust this folder"), 60):
            rpc("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script"})
            time.sleep(0.5)  # test harness: the terminal takes focus
            rpc("debug.key", {"key": "down"})
            rpc("debug.key", {"key": "return"})
    # The reply, not the echoed prompt: the URL's end and a path line without "Line 2:".
    rows = wait_for(lambda: (lambda r: r if r and sum(marker in row for row in r) >= 2
                             and any("src/app.ts:3:5" in row and "Line" not in row for row in r) else None)(viewport_rows(marker)),
                    f"{name} printed the URL and the path", 240)
    if not rows:
        texts = [pane.get("text") or "" for window in rpc("debug.surfaces", {"text": True}).get("windows") or []
                 for pane in window.get("panes") or []]
        with open(os.path.join(opts.out, f"{kind}-screen.txt"), "w") as f:
            f.write("\n=====\n".join(texts))
        snapshot(f"{kind}-no-reply")
        return
    time.sleep(3)  # test harness: the agent finishes drawing its turn
    rows = viewport_rows(marker) or rows or []
    with open(os.path.join(opts.out, f"{kind}-viewport.txt"), "w") as f:
        f.write("\n".join(rows))
    # The last copy of the URL on screen: the agent's reply.
    end = max((i for i, row in enumerate(rows) if marker in row), default=None)
    start = None
    if end is not None:
        start = max((i for i in range(end + 1) if f"https://example.com/{kind}-check" in rows[i]), default=None)
    check(start is not None and end is not None, f"found the URL {name} drew (rows {start}..{end})")
    if start is None or end is None:
        return
    report[f"{kind}_rows"] = [start, end]
    check(end > start, f"{name} drew the URL on {end - start + 1} rows")
    col = rows[start].index("https://") + 10
    hover(col, start, keys=())
    links(modifiers=["command"])
    settle()
    state = hover(col + 1, start)
    print(f"pointer over {name}'s URL: hovered={state.get('hovered')!r} wrapped={(state.get('wrapped') or '')[:40]!r} hand={state.get('pointingHand')}", flush=True)
    time.sleep(2)  # test harness: a later shape change from Ghostty or the program would show here
    later = links()
    print(f"2 s later: hovered={later.get('hovered')!r} wrapped={(later.get('wrapped') or '')[:40]!r} hand={later.get('pointingHand')}", flush=True)
    shown = state.get("wrapped") or state.get("hovered")
    check(shown == url, f"Command over {name}'s URL shows the whole URL ({(shown or '')[:70]!r})")
    check(state.get("pointingHand") is True, f"the pointer shows the pointing hand over {name}'s URL ({state.get('pointingHand')!r})")
    if end > start:
        check(state.get("wrapped") == url, f"every row of {name}'s URL is underlined ({(state.get('wrapped') or '')[:50]!r})")
    snapshot(f"{kind}-url-hover")
    opened = click(col + 1, start)
    check(opened == [f"system:{url}"], f"Cmd-click on {name}'s URL opens it whole ({[o[:80] for o in opened]})")
    if end > start:
        last = rows[end]
        lcol = max(0, last.index(marker) - 2)
        hover(lcol, end)
        opened = click(lcol, end)
        check(opened == [f"system:{url}"], f"Cmd-click on the URL's last row opens it whole ({[o[:80] for o in opened]})")
    prow = max((i for i, row in enumerate(rows) if "src/app.ts:3:5" in row and "Line" not in row), default=None)
    if check(prow is not None, f"found the path {name} drew"):
        pcol = rows[prow].index("src/app.ts:3:5") + 4
        hover(pcol, prow)
        hover(pcol + 1, prow)
        state = links()
        snapshot(f"{kind}-path-hover")
        opened = click(pcol + 1, prow)
        check(any(entry.startswith("file:") and entry.endswith("src/app.ts:3:5") for entry in opened),
              f"Cmd-click on {name}'s src/app.ts:3:5 opens the file at line 3, column 5 ({opened}; hovered {state.get('hovered')!r})")
        time.sleep(2)  # test harness: the editor page loads
        snapshot(f"{kind}-editor-at-line")
    links(modifiers=[])
    for _ in range(3):  # the agent quits on a second Ctrl-C
        send("\x03")
        time.sleep(1)  # test harness: the agent handles each Ctrl-C


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"terminal-cmd-click-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
with open(GHOSTTY, "w") as f:
    f.write("link-previews = true\n")
with open(CONFIG, "w") as f:
    json.dump({"browser": {"openLinksInCmuxBrowser": False}}, f)
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, repo {REPO}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 180)
    check("error" not in rpc("debug.terminal.links"), "the build has debug.terminal.links")
    if not quiet_wait(lambda: rpc("debug.focus").get("windows"), 20):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait_for(lambda: rpc("debug.focus").get("windows"), "a window", 60)
    made = rpc("action.run", {"action": "workspace new", "args": {"cwd": os.path.join(REPO, "sub"), "focus": True}, "origin": "script"})
    workspace = (made.get("created") or [None])[0]

    def fixture_terminal():
        global TERMINAL
        for listed in (rpc("snapshot.get").get("topology") or {}).get("workspaces") or []:
            if listed.get("id") != workspace:
                continue
            for screen in listed.get("screens") or []:
                for pane in screen.get("panes") or []:
                    for tab in pane.get("tabs") or []:
                        if tab.get("kind") in ("terminal", "pty") and "error" not in rpc("debug.terminal.links", {"tab": tab["id"]}):
                            TERMINAL = tab["id"]
                            return TERMINAL
        return None

    if not quiet_wait(fixture_terminal, 10):
        for index in range(1, 10):
            rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
            if quiet_wait(fixture_terminal, 3):
                break
    if not wait_for(fixture_terminal, "the new workspace's terminal", 30):
        print(f"workspace new: {json.dumps(made)[:400]}", flush=True)
        print(f"snapshot.get: {json.dumps(rpc('snapshot.get'))[:2500]}", flush=True)
    rpc("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script"})
    time.sleep(2)  # test harness: the shell starts and reports its cwd

    # Plain shell. Row 0: a URL; rows 2-: a URL longer than any row, soft-wrapped by the shell.
    soft = "https://example.com/soft/" + "a" * 400
    send(f"clear && printf '%s\\n\\n%s\\n' https://example.com/plain-shell {soft}\n")
    time.sleep(2)  # test harness: the shell runs the command and the output draws

    # 1. The pointer rests on the URL; Command goes down; then the click.
    hover(3, 0, keys=())
    snapshot("plain-shell-pointer-no-command")
    links(modifiers=["command"])
    settle()
    state = links()
    check(state.get("hovered") == "https://example.com/plain-shell",
          f"Command pressed with the pointer still shows the link ({state.get('hovered')!r})")
    snapshot("plain-shell-command-down")
    opened = click(3, 0)
    check(opened == ["system:https://example.com/plain-shell"], f"Cmd-click on the first cell opens the URL ({opened})")
    links(modifiers=[])

    # 4. The soft-wrapped URL opens whole from its second row.
    hover(5, 3)
    opened = click(5, 3)
    check(opened == [f"system:{soft}"], f"a soft-wrapped URL opens whole from its second row ({[o[:60] for o in opened]})")

    # 3. Shift-Command.
    hover(3, 0, keys=("command", "shift"))
    opened = click(3, 0, keys=("command", "shift"))
    check(any(entry.endswith("https://example.com/plain-shell") for entry in opened),
          f"Shift-Command-click opens the URL ({opened})")

    # 2. A terminal without focus: split right (the new pane takes focus), then the same.
    rpc("action.run", {"action": "splitRight", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script"})
    time.sleep(2)  # test harness: the split's terminal starts and takes focus
    send("clear && printf '%s\\n' https://example.com/plain-shell\n")
    time.sleep(1.5)  # test harness: output draws
    links(modifiers=[])
    hover(3, 0, keys=())
    links(modifiers=["command"])
    settle()
    state = links()
    check(state.get("hovered") == "https://example.com/plain-shell",
          f"Command pressed over a terminal without focus shows the link ({state.get('hovered')!r})")
    snapshot("unfocused-command-down")
    opened = click(3, 0)
    check(opened == ["system:https://example.com/plain-shell"], f"Cmd-click in a terminal without focus opens the URL ({opened})")
    links(modifiers=[])
    settle()
    check(not links().get("hovered"), "releasing Command clears the link")

    # The fixture TUI.
    send(f"clear && /usr/bin/python3 {TUI} {LAYOUT} {TUI_LOG} '{LONG_URL}'\n")
    layout = wait_for(lambda: os.path.exists(LAYOUT) and json.load(open(LAYOUT)), "the fixture TUI draws", 30)
    layout = layout or {}
    time.sleep(1)  # test harness: the TUI's frame draws
    snapshot("tui")

    # 5. Cmd-hover on a URL in the program.
    col, row = layout.get("plain", [12, 2])
    hover(col, row, keys=())
    snapshot("tui-pointer-no-command")
    # As a person does: the pointer rests on the URL, Command goes down, the pointer moves a cell.
    links(modifiers=["command"])
    settle()
    state = links()
    check(state.get("hovered") == "https://example.com/tui-plain",
          f"Command pressed over a URL in a mouse-reading program shows the link ({state.get('hovered')!r})")
    col += 1
    state = hover(col, row)
    check(state.get("hovered") == "https://example.com/tui-plain", f"Cmd-hover in a mouse-reading program finds the URL ({state.get('hovered')!r})")
    check(state.get("pointingHand") is True, f"the pointer shows the pointing hand ({state.get('pointingHand')!r})")
    snapshot("tui-cmd-hover")

    # 6. Cmd-click opens; the program sees no press. A plain click still reaches it.
    before = presses()
    opened = click(col, row)
    check(opened == ["system:https://example.com/tui-plain"], f"Cmd-click in a mouse-reading program opens the URL ({opened})")
    check(presses() == before, f"the program sees no press from the Cmd-click ({presses() - before} new)")
    links(modifiers=[])
    settle()
    hover(col, row, keys=("command", "option"))
    hover(col + 1, row, keys=("command", "option"))
    before = presses()
    opened = click(col + 1, row, keys=("command", "option"))
    check(len(opened) == 1 and opened[0].endswith("https://example.com/tui-plain"),
          f"Option-Command-click in a mouse-reading program opens the URL ({opened})")
    check(presses() == before, f"the program sees no press from the Option-Command-click ({presses() - before} new)")
    links(modifiers=[])
    settle()
    tcol, trow = layout.get("text", [4, 20])
    hover(tcol, trow, keys=())
    before = presses()
    click(tcol, trow, keys=())
    time.sleep(0.5)  # test harness: the report reaches the program through the daemon
    check(presses() - before == 2, f"a plain click still reaches the program, press and release ({presses() - before} new)")

    # 7. OSC 8.
    col, row = layout.get("osc8", [12, 4])
    hover(col, row)
    snapshot("tui-osc8-hover")
    opened = click(col, row)
    check(opened == ["system:https://example.com/osc8-target"], f"Cmd-click on an OSC 8 link opens its target ({opened})")

    # 8. The URL the program broke onto rows itself.
    (c1, r1), (c2, r2) = layout.get("wrapped", [[4, 6], [4, 7]])
    hover(c1 + 20, r1)
    snapshot("tui-wrapped-hover-first-row")
    state = hover(c2, r2)
    check(state.get("wrapped") == LONG_URL, f"Cmd-hover on the second row reports the whole URL ({(state.get('wrapped') or '')[:50]!r})")
    snapshot("tui-wrapped-hover-second-row")
    opened = click(c2, r2)
    check(opened == [f"system:{LONG_URL}"], f"Cmd-click on the second row opens the whole URL ({[o[:60] for o in opened]})")
    hover(c1 + 20, r1)
    opened = click(c1 + 20, r1)
    check(opened == [f"system:{LONG_URL}"], f"Cmd-click on the first row opens the whole URL ({[o[:60] for o in opened]})")

    # 9. A path with a line and column.
    col, row = layout.get("path", [12, 9])
    hover(col, row)
    settle()
    state = links()
    snapshot("tui-path-hover")
    opened = click(col, row)
    expected = f"file:{os.path.join(REPO, 'src', 'app.ts')}:3:5"
    check(any(os.path.realpath(entry[5:].rsplit(":", 2)[0]) == os.path.join(REPO, "src", "app.ts") for entry in opened if entry.startswith("file:")),
          f"Cmd-click on src/app.ts:3:5 opens the file ({opened}; hovered {state.get('hovered')!r})")
    check(any(entry.endswith(":3:5") for entry in opened), f"the file opens at line 3, column 5 ({opened}, want {expected})")
    time.sleep(2)  # test harness: the editor page loads
    snapshot("editor-at-line")
    send("q")
    time.sleep(1)  # test harness: the fixture TUI leaves the alternate screen
    for spec in opts.agent:
        kind, _, path = spec.partition("=")
        run_agent(kind, path)
finally:
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        report["failures"] = failures
        json.dump(report, f, indent=1)
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"RESULT {'FAIL' if failures else 'PASS'} ({len(failures)} failed)", flush=True)
sys.exit(1 if failures else 0)
