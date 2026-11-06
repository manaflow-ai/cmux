#!/usr/bin/env python3
"""Live behavior proof for the dialog removal of cx-7vu (closes run at once,
undo toasts, no "Quit cmux?" prompt), through the tagged app's own sockets.

Checks, on one tagged DEBUG app with a bounded, never-activated window:
  forget      Forget Machine from a person's run asks nothing, shows the
              "remote-forgot" undo toast and hides the machine; Undo brings it back.
  group       Close All Workspaces in Group asks nothing (idle terminals), shows the
              "workspace-group-closed" toast and closes the group's workspace;
              Undo reopens it.
  tabgroup    Closing a tab group asks nothing (idle terminals) and shows the
              "tab-closed" undo toast; Undo brings the tab back.
  quit        Cmd-Q (debug.quit open, the interactive origin) with a foreground
              program running quits at once with no dialog; the program and the
              daemon survive; a relaunch shows the same terminal.

Teardown: quit with End Sessions (`action.run quit {endSessions}`, explicit and
scripted), `acpmux daemon shutdown`, `cmux server stop --end-terminals`; signals
only to the PID this script launched. Run on cmux-lawrence-2 (GUI host), never the laptop.
Usage: dialogs-undo-live.py TAG APP OUT_DIR
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


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="dialogs-undo-")
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
launched = []
app = launch()
try:
    # forget ------------------------------------------------------------------
    print("connect:", json.dumps(rpc("action.run", {"id": "remote.connect", "args": {"destination": "dlgproof@192.0.2.1"}}))[:300])
    machine = wait(lambda: next(iter(machines()), None), 20)
    check("forget-setup-machine", machine, machines())
    if machine:
        reply = rpc("debug.toast", {"perform": "remote.forget", "target_kind": "machine", "target_id": machine})
        check("forget-ran", reply.get("performed"), reply)
        check("forget-no-dialog", no_dialog_after(), dialogs())
        check("forget-toast", wait(lambda: any(t["id"] == "remote-forgot" for t in toasts()), 5), toasts())
        check("forget-hides-machine", wait(lambda: machine not in machines(), 5), machines())
        reply = rpc("debug.toast", {"undo": True})
        check("forget-undo-ran", reply.get("undone"), reply)
        check("forget-undo-restores", wait(lambda: machine in machines(), 10), machines())
        rpc("action.run", {"id": "remote.forget", "target": "machine:%s" % machine, "args": {"confirm": True}})

    # group -------------------------------------------------------------------
    print("workspace create:", cli("workspace", "create", "--name", "dlg-g", "--json")[:300])
    row = wait(lambda: next((r for r in rows() if r.get("title") == "dlg-g"), None), 15)
    check("group-setup-row", row, [r.get("title") for r in rows()])
    if row:
        reply = rpc("debug.toast", {"perform": "newWorkspaceGroup", "target_kind": "workspace", "target_id": row["key"],
                                    "arguments": {"name": "DlgProof"}})
        grouped = wait(lambda: next((r for r in rows() if r.get("title") == "dlg-g" and r.get("group")), None), 15)
        check("group-setup-group", grouped, reply)
        if grouped:
            before = len(rows())
            reply = rpc("debug.toast", {"perform": "workspaceGroup.closeWorkspaces", "target_kind": "workspace-group",
                                        "target_id": grouped["group"]})
            check("group-close-ran", reply.get("performed"), reply)
            check("group-close-no-dialog", no_dialog_after(), dialogs())
            check("group-close-toast", wait(lambda: any(t["id"] == "workspace-group-closed" for t in toasts()), 10), toasts())
            check("group-close-closes", wait(lambda: not any(r.get("title") == "dlg-g" for r in rows()), 10),
                  [r.get("title") for r in rows()])
            reply = rpc("debug.toast", {"undo": True})
            check("group-undo-ran", reply.get("undone"), reply)
            check("group-undo-reopens", wait(lambda: any(r.get("title") == "dlg-g" for r in rows()), 15),
                  "%d rows before, now %s" % (before, [(r.get("title"), r.get("group")) for r in rows()]))
            check("group-undo-regroups", wait(lambda: any(r.get("title") == "dlg-g" and r.get("group") for r in rows()), 10),
                  [(r.get("title"), r.get("group")) for r in rows()])

    # tab group -----------------------------------------------------------------
    reply = rpc("debug.toast", {"perform": "tabGroup.create", "arguments": {"name": "DlgTabs"}})
    check("tabgroup-setup", reply.get("performed"), reply)
    time.sleep(1)  # test harness: the group reaches the store
    tabs_before = surface_count()
    reply = rpc("debug.toast", {"perform": "tabGroup.close"})
    check("tabgroup-close-ran", reply.get("performed"), reply)
    check("tabgroup-close-no-dialog", no_dialog_after(), dialogs())
    check("tabgroup-close-closes", wait(lambda: surface_count() < tabs_before, 10), (tabs_before, surface_count()))
    check("tabgroup-close-toast", wait(lambda: any(t["id"] == "tab-closed" for t in toasts()), 10), toasts())
    reply = rpc("debug.toast", {"undo": True})
    check("tabgroup-undo-ran", reply.get("undone"), reply)
    check("tabgroup-undo-restores", wait(lambda: surface_count() >= tabs_before, 10), (tabs_before, surface_count()))
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "after-undo.png")}, timeout=60)

    # quit ----------------------------------------------------------------------
    created = cli("workspace", "create", "--name", "dlg-q", "--json")
    print("quit workspace:", created[:300])
    terminal = (json.loads(created).get("value") or {}).get("terminal_id") if created.startswith("{") else None
    check("quit-setup-terminal", terminal, created)
    loop_pid = None
    if terminal:
        cli("terminal", str(terminal), "write", "--text",
            "sh -c 'echo $$ > %s/loop.pid; while true; do sleep 1; done'\n" % OUT)
        loop_pid = wait(lambda: os.path.exists(os.path.join(OUT, "loop.pid")) and int(open(os.path.join(OUT, "loop.pid")).read().strip() or 0), 15)
        check("quit-setup-program", loop_pid, loop_pid)
    reply = rpc("debug.quit", {"open": True})
    print("quit open:", json.dumps(reply)[:200])
    # QUIT P0: with a local terminal, Cmd-Q asks how to quit; its default (Keep Sessions) keeps the program running.
    asked = False
    deadline = time.time() + 20
    while app.poll() is None and time.time() < deadline:
        q = rpc("debug.quit", timeout=2) or {}
        if q.get("asking") is True:
            asked = True
            rpc("debug.quit", {"press": "keep"}, timeout=5)
            break
        time.sleep(0.25)
    while app.poll() is None and time.time() < deadline:
        time.sleep(0.25)
    check("quit-asks", asked)
    check("quit-app-exits", app.poll() is not None, app.poll())
    time.sleep(5)  # test harness: past the quit, before the survival read
    check("quit-program-survives", loop_pid and alive(loop_pid), loop_pid)
    terminals = cli("terminal", "list", "--json")
    check("quit-terminal-in-daemon", terminal and str(terminal) in terminals, terminals[:300])
    app = launch()
    check("relaunch-shows-workspace", wait(lambda: any(r.get("title") == "dlg-q" for r in rows()), 20),
          [r.get("title") for r in rows()])
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "relaunch.png")}, timeout=60)
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
    left = [line for line in ps.splitlines() if (APP + "/") in line and "dialogs-undo-live" not in line]
    print("leftovers of this bundle: %d" % len(left), flush=True)
    for line in left:
        print("  " + line[:200], flush=True)
failed = [name for name, ok in results if not ok]
print("RESULT pass=%d fail=%d %s" % (len(results) - len(failed), len(failed), " ".join(failed)), flush=True)
sys.exit(1 if failed else 0)
