#!/usr/bin/env python3
"""Live check of the standard terminal keys on a tagged cmux-next build (cmux-lawrence-2 only).

Decision K1: Cmd-K clears the focused terminal's screen and scrollback, also inside a split, and
does nothing else when an agent chat has the keyboard. The script launches the tagged app itself
(no activation, scratch config, empty Ghostty config), fills a terminal with 400 numbered lines,
presses Cmd-K through `debug.key`, and reads the terminal before and after: the app's rendered
viewport (`debug.surfaces` text) and the daemon's screen and history (`cmux terminal ... read`,
`history read`). It also presses Cmd-=, Cmd-0, Cmd-Up and Cmd-Shift-G in the terminal and prints
which owner took each key (`debug.key` handled_by / action / trace).

On exit it quits the app with quitEndSessions, stops the tag's cmux-tui session and kills any
process left from the tag's bundle by exact PID.

Usage: terminal-keys-e2e.py --tag <tag> --app PATH [--out DIR]
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True, help="the tagged .app bundle")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
TAG, APP = opts.tag, opts.app.rstrip("/")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
# The bundle's executable (MacOS/ also holds the debug and preview dylibs).
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"keys-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
ROWS = []


SESSION = []


def find_session():
    """The tag's daemon session socket (the CLI's default is the release app's)."""
    SESSION[:] = ["--session", f"cmux-app-{TAG}"]


def run(*args, timeout=30):
    """The bundled CLI against the tagged app (as scripts/cmux-debug-cli.sh sets it up)."""
    env = {**ENV, "CMUX_TAG": TAG, "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


def terminal_ids():
    return set(re.findall(r"term_[0-9a-f]+", run("terminal", "list").stdout))


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


def daemon_text(ref):
    screen = run("terminal", ref, "read").stdout
    history = run("terminal", ref, "history", "read", "--limit", "2000").stdout
    return screen, history


def numbers(text):
    return {int(n) for n in re.findall(r"(?m)^\s*(\d{1,3})\s*$", text)}


def key(name, modifiers):
    return rpc("debug.key", {"key": name, "modifiers": modifiers})


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def fill(pane_key, ref):
    print("write:", run("terminal", ref, "write", "--text", "clear; seq 1 400\n").stderr[-200:], flush=True)
    return wait(lambda: "400" in viewport(pane_key), 15)


def clear_check(label, ref):
    pane = focused_pane()
    if not pane or pane.get("kind") != "terminal":
        row(label, "a focused terminal", f"focused={pane and pane.get('kind')}", False)
        return
    key_ = pane["pane"]
    filled = fill(key_, ref)
    screen_before, history_before = daemon_text(ref) if ref else ("", "")
    before = numbers(viewport(key_))
    reply = key("k", ["cmd"])
    time.sleep(1.5)  # test harness: let the clear render and reach the daemon
    after_view = numbers(viewport(key_))
    screen_after, history_after = daemon_text(ref) if ref else ("", "")
    print(f"--- {label}: debug.key {json.dumps(reply)[:400]}", flush=True)
    print(f"daemon screen after: {screen_after[-300:]!r}", flush=True)
    print(f"daemon history after: {history_after[-300:]!r}", flush=True)
    row(f"{label}: Cmd-K owner", "action terminal.clear", f"handled_by={reply.get('handled_by')} action={reply.get('action')}",
        reply.get("action") == "terminal.clear")
    row(f"{label}: viewport cleared", "no numbered lines", f"filled={bool(filled)} before={len(before)} after={len(after_view)}",
        bool(filled) and len(before) > 10 and not after_view)
    row(f"{label}: daemon screen cleared", "no numbered lines",
        f"before={len(numbers(screen_before))} after={len(numbers(screen_after))}", not numbers(screen_after))
    row(f"{label}: daemon history cleared", "no numbered lines",
        f"before={len(numbers(history_before))} after={len(numbers(history_after))} ref={ref}", not numbers(history_after))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"keys-{label.replace(' ', '-')}.png")})


app = None


def cleanup():
    print("cleanup", flush=True)
    if os.environ.get("KEYS_E2E_KEEP"):
        return
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
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        print("debug.surfaces:", json.dumps(rpc("debug.surfaces"))[:800], flush=True)
        print("debug.windows:", json.dumps(rpc("debug.windows"))[:800], flush=True)
        sys.exit("the tagged app did not come up")
    # Earlier runs of this script left their workspaces in the tag's state: close them.
    for old in set(re.findall(r"(ws_[0-9a-f]+)\s+keys-e2e", run("workspace", "list").stdout)):
        run("workspace", old, "close")
    made = run("workspace", "create", "--name", "keys-e2e")
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
        if wait(lambda: any(p.get("selected_tab") == (tab and tab.group(1)) for p in panes()), 3):
            print("new workspace is number", index, flush=True)
            break
    if not wait(lambda: (focused_pane() or {}).get("kind") == "terminal", 30):
        print("panes:", json.dumps(panes())[:1500], flush=True)
    time.sleep(2)  # test harness: shell prompt
    clear_check("single terminal", terminal.group(1) if terminal else "")
    before = terminal_ids()
    print("splitRight:", rpc("action.run", {"action": "splitRight"}), flush=True)
    new = wait(lambda: terminal_ids() - before, 10)
    if not new:
        # The new split may open on the New Tab page (the default kind): open a terminal tab in it.
        print("newSurface in split:", rpc("action.run", {"action": "newSurface"}), flush=True)
        new = wait(lambda: terminal_ids() - before, 20)
    wait(lambda: (focused_pane() or {}).get("kind") == "terminal" and len(panes()) >= 2, 30)
    time.sleep(2)  # test harness: shell prompt
    # Automation never moves focus: the original terminal keeps it, now inside a split.
    clear_check("split terminal (left, focused)", terminal.group(1) if terminal else "")
    # The user's Cmd-Option-Right moves focus to the new split; Cmd-K clears that one.
    print("focus right:", key("right", ["cmd", "option"]).get("action"), flush=True)
    time.sleep(1)  # test harness: focus settles
    clear_check("split terminal (right)", sorted(new)[0] if new else "")
    for name, mods, label in [("=", ["cmd"], "Cmd-="), ("0", ["cmd"], "Cmd-0"), ("up", ["cmd"], "Cmd-Up"),
                              ("g", ["cmd", "shift"], "Cmd-Shift-G"), ("left", ["option"], "Option-Left")]:
        reply = key(name, mods)
        owner = f"handled_by={reply.get('handled_by')} action={reply.get('action')} trace={str(reply.get('trace'))[-160:]}"
        row(f"terminal {label}", "the terminal (Ghostty) gets it", owner, not reply.get("action"))
    print("newAgentChat:", rpc("action.run", {"action": "palette.newAgentChat"}), flush=True)
    time.sleep(2)  # test harness: a new chat may open in a new workspace (L3)
    for index in range(1, 10):
        if (focused_pane() or {}).get("kind") == "agent":
            break
        rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
        wait(lambda: (focused_pane() or {}).get("kind") == "agent", 3)
    wait(lambda: (focused_pane() or {}).get("kind") not in (None, "terminal"), 30)
    time.sleep(3)  # test harness: the agent page loads
    pane = focused_pane() or {}
    reply = key("k", ["cmd"])
    row("agent composer Cmd-K", "no cmux action", f"focused={pane.get('kind')} handled_by={reply.get('handled_by')} action={reply.get('action')}",
        not reply.get("action") and pane.get("kind") != "terminal")
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "keys-agent.png")})


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
