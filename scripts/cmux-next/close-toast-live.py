#!/usr/bin/env python3
"""Live behavior proof of the close toast rule (Lawrence 2026-10-12, "this toast
shows up too often"), through a tagged app's own sockets: closing Settings or an
idle terminal shows no toast; closing a terminal running `sleep` shows the undo
toast, and Undo runs. cx-lb4al follow-ups: a pane's close others over three
panes with one idle tab each is one costly gesture (one toast for 3 tabs); a tab
group whose only tab runs `sleep` closes with the toast (its program is read
before the close). Run on cmux-lawrence-2 (GUI host), never the laptop.
Usage: close-toast-live.py TAG APP OUT_DIR
"""
import json, os, pwd, signal, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
SESSION = "cmux-app-%s" % TAG
ACPMUX_HOME = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".cmux/chief/isolated", TAG, "acpmux")
os.makedirs(OUT, exist_ok=True)
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("%s %s %s" % ("PASS" if ok else "FAIL", name, str(detail)[:400]), flush=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    r = subprocess.run([CLI, "--session", SESSION, *args], env=env, capture_output=True, text=True, timeout=60)
    return r.stdout.strip() or r.stderr.strip()


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def toasts():
    return [t for w in (rpc("debug.toast") or {}).get("windows", []) for t in w.get("toasts", [])]


def dialogs():
    return (rpc("debug.dialog") or {}).get("dialogs", [])


def rows():
    return [r for w in (rpc("debug.sidebar_rows") or {}).get("windows", []) for r in w.get("rows", [])]


def surface_count():
    reply = rpc("debug.surfaces") or {}
    for key in ("surfaces", "tabs", "targets"):
        if isinstance(reply.get(key), list):
            return len(reply[key])
    return json.dumps(reply).count('"surface')


def no_dialog_after(seconds=1.5):
    """A question is decided in a task after the run: give it time to show."""
    time.sleep(seconds)  # test harness: the confirmation presenter is async
    return not dialogs()


def machines():
    reply = rpc("remote.machines") or {}
    return [m.get("id") for m in (reply.get("machines") if isinstance(reply, dict) else reply) or []]


def launch():
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    launched.append(app)
    print("launched pid %d" % app.pid, flush=True)
    wins = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180, 0.5)
    check("launch-%d" % len(launched), wins, json.dumps(wins)[:200])
    return app


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False



def undo_state(label):
    """Why a close showed or skipped its toast (`debug.filepages` undo: gestures waiting, closed items matched)."""
    print("undo %s:" % label, json.dumps((rpc("debug.filepages") or {}).get("undo"))[:900], flush=True)


SHELLS = {"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"}


def foreground(terminal_id):
    """The daemon's foreground program of a terminal (`terminal.process.get`), as the close rule reads it."""
    out = cli("terminal", terminal_id, "process", "show", "--json")
    try:
        reply = json.loads(out)
    except ValueError:
        return out
    value = reply.get("value", reply) if isinstance(reply, dict) else {}
    return os.path.basename(str((value or {}).get("foreground_executable") or "")).lstrip("-")


def tab_closed_toasts():
    return [t for t in toasts() if t["id"] == "tab-closed"]


def close_tab(tab_id=None):
    params = {"perform": "closeTab"}
    if tab_id:
        params.update({"target_kind": "tab", "target_id": tab_id})
    return rpc("debug.toast", params)


def no_toast_for(seconds=3):
    time.sleep(seconds)  # test harness: the toast shows once the daemon records the close
    return not tab_closed_toasts()


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="close-toast-")
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
# No close question: this proof is about the toast, and a question would wait for a person.
open(CONFIG, "w").write(json.dumps({"app": {"warnBeforeClosingTab": False, "warnBeforeClosingAgentSession": False}}))
open(GHOSTTY, "w").write("")
launched = []
app = launch()
try:
    # Settings closes with no toast.
    reply = rpc("debug.toast", {"perform": "openSettings"})
    check("settings-open", reply.get("performed"), reply)
    time.sleep(2)  # test harness: the Settings tab opens and takes focus
    reply = close_tab()
    check("settings-close-ran", reply.get("performed"), reply)
    check("settings-close-no-toast", no_toast_for(), toasts())

    def second_tab(name):
        """A workspace with two terminal tabs: closing the second closes only that tab."""
        made = cli("workspace", "create", "--name", name, "--json")
        first = (json.loads(made).get("value") or {}) if made.startswith("{") else {}
        pane = first.get("pane_id")
        extra = cli("tab", "create", "terminal", "--pane", pane or "", "--json") if pane else ""
        value = (json.loads(extra).get("value") or {}) if extra.startswith("{") else {}
        # Shown in the window, as a person's close is: a hidden workspace's tab closes without the strip.
        shown = rpc("action.run", {"action": "tab.focus", "target": "tab:%s" % first.get("tab_id"), "focus": True, "wait": True})
        print("reveal %s:" % name, json.dumps(shown)[:200], flush=True)
        time.sleep(1)  # test harness: the pane controller is made
        return pane, value

    def pane_tabs(pane):
        listed = cli("tab", "list", "--json")
        try:
            rows = json.loads(listed)
        except ValueError:
            return -1
        rows = rows.get("value", rows) if isinstance(rows, dict) else rows
        return sum(1 for row in rows if isinstance(row, dict) and row.get("pane_id") == pane)

    # An idle terminal closes with no toast.
    pane, value = second_tab("ct-idle")
    check("idle-setup", value.get("tab_id"), value)
    if value.get("tab_id"):
        time.sleep(1)  # test harness: the shell starts
        before = pane_tabs(pane)
        # Idle means the shell owns the terminal: its startup (prompt hooks) may still run a program.
        idle = wait(lambda: foreground(value["terminal_id"]) in SHELLS, 15)
        print("idle foreground:", foreground(value["terminal_id"]), flush=True)
        check("idle-shell-idle", idle, foreground(value["terminal_id"]))
        reply = close_tab(value["tab_id"])
        check("idle-close-ran", reply.get("performed"), reply)
        check("idle-close-closes", wait(lambda: pane_tabs(pane) == before - 1, 10), (before, pane_tabs(pane)))
        check("idle-close-no-toast", no_toast_for(), toasts())
        undo_state("idle")

    # A terminal running `sleep` closes with the undo toast; Undo brings it back.
    pane, value = second_tab("ct-busy")
    check("busy-setup", value.get("tab_id"), value)
    if value.get("tab_id"):
        cli("terminal", value["terminal_id"], "write", "--text", "sleep 1000\n")
        time.sleep(2)  # test harness: sleep becomes the foreground program
        before = pane_tabs(pane)
        reply = close_tab(value["tab_id"])
        check("busy-close-ran", reply.get("performed"), reply)
        check("busy-close-closes", wait(lambda: pane_tabs(pane) == before - 1, 10), (before, pane_tabs(pane)))
        shown = wait(lambda: tab_closed_toasts(), 10)
        check("busy-close-toast", shown, toasts())
        reply = rpc("debug.toast", {"undo": True})
        check("busy-undo-ran", reply.get("undone"), reply)
        check("busy-undo-restores", wait(lambda: pane_tabs(pane) == before, 10), (before, pane_tabs(pane)))

    def tab_rows():
        try:
            rows = json.loads(cli("tab", "list", "--json"))
        except ValueError:
            return []
        rows = rows.get("value", rows) if isinstance(rows, dict) else rows
        return [row for row in rows if isinstance(row, dict)]

    def dismiss_toasts():
        """The next case starts with no close toast to join (a toast lasts a few seconds)."""
        return wait(lambda: not tab_closed_toasts(), 20)

    # cx-lb4al item 1: close others over 3 panes with one idle tab each shows ONE toast for 3 tabs.
    dismiss_toasts()
    made = cli("workspace", "create", "--name", "ct-others", "--json")
    first = (json.loads(made).get("value") or {}) if made.startswith("{") else {}
    p0 = first.get("pane_id")
    print("others workspace:", made[:300], flush=True)
    if p0:
        rpc("action.run", {"action": "tab.focus", "target": "tab:%s" % first.get("tab_id"), "focus": True, "wait": True})
        known = {p0}

        def split(target, side):
            out = cli("pane", target, "split", side, "--json")
            print("split %s %s:" % (target, side), out[:300], flush=True)
            new_pane = ((json.loads(out).get("value") or {}).get("pane_id")) if out.startswith("{") else None
            # A reply without the new pane's id: take it from the tab list of this workspace.
            ws = first.get("workspace_id")
            found = {new_pane} if new_pane else {r.get("pane_id") for r in tab_rows() if ws and r.get("workspace_id") == ws}
            known.update(p for p in found if p)
            return new_pane

        right = split(p0, "--right")
        split(p0, "--down")
        split(right or p0, "--down")
        panes = sorted(known)
        in_ws = lambda: sum(1 for r in tab_rows() if r.get("pane_id") in known)
        check("others-setup", len(panes) == 4, panes)
        time.sleep(2)  # test harness: the shells start and the pane controllers are made
        # Shown in the window, as a person's right-click is: a hidden pane has no strip to close from.
        rpc("action.run", {"action": "tab.focus", "target": "tab:%s" % first.get("tab_id"), "focus": True, "wait": True})
        shown_panes = lambda: all(p in json.dumps(rpc("debug.pane_chrome")) for p in panes)
        check("others-shown", wait(shown_panes, 15), json.dumps(rpc("debug.pane_chrome"))[:300])
        before = in_ws()
        reply = rpc("debug.toast", {"perform": "pane.closeOthers", "target_kind": "pane", "target_id": p0})
        check("others-close-ran", reply.get("performed"), reply)
        check("others-close-closes", wait(lambda: in_ws() == 1, 10), (before, in_ws()))
        # Each pane's records join the showing toast: it ends as one "Closed 3 tabs" toast.
        shown = wait(lambda: [t for t in tab_closed_toasts() if "3 tabs" in t.get("message", "")], 10)
        check("others-close-one-toast", shown and len(tab_closed_toasts()) == 1, toasts())
        undo_state("others")

    # cx-lb4al item 2: a tab group whose one tab runs `sleep` closes with the toast.
    dismiss_toasts()
    pane, value = second_tab("ct-group")
    check("group-setup", value.get("tab_id"), value)
    if value.get("tab_id"):
        cli("terminal", value["terminal_id"], "write", "--text", "sleep 1000\n")
        made = cli("tab", "group", "create", "--tabs", value["tab_id"], "--name", "busy", "--json")
        print("group:", made[:300], flush=True)
        group = (json.loads(made).get("value") or {}).get("id") if made.startswith("{") else None
        check("group-created", group, made)
        time.sleep(2)  # test harness: sleep becomes the foreground program
        before = pane_tabs(pane)
        reply = rpc("debug.toast", {"perform": "tabGroup.close", "target_kind": "tab-group", "target_id": group or ""})
        check("group-close-ran", reply.get("performed"), reply)
        check("group-close-closes", wait(lambda: pane_tabs(pane) == before - 1, 10), (before, pane_tabs(pane)))
        shown = wait(lambda: tab_closed_toasts(), 10)
        check("group-close-toast", shown, toasts())
        undo_state("group")
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "end.png")}, timeout=60)
finally:
    print("teardown quit:", json.dumps(rpc("action.run", {"id": "quit", "args": {"endSessions": True}}, timeout=10))[:200])
    for proc in launched:
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            print("pid %d did not quit; SIGKILL" % proc.pid, flush=True)
            os.kill(proc.pid, signal.SIGKILL)  # the PID launched here, never a pattern
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                   "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}, capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", SESSION, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    time.sleep(3)  # test harness: let daemons exit before the leftover check
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    left = [line for line in ps.splitlines() if (APP + "/") in line and "close-toast-live" not in line]
    print("leftovers of this bundle: %d" % len(left), flush=True)
failed = [name for name, ok in results if not ok]
print("RESULT pass=%d fail=%d %s" % (len(results) - len(failed), len(failed), " ".join(failed)), flush=True)
sys.exit(1 if failed else 0)
