#!/usr/bin/env python3
"""GUI dogfood of the terminal holder model (perf lead, holder item 4), and its process and memory A/B.

Launches a tagged Debug app with `CMUX_NEXT_TUI_TERMINAL_HOST_MODEL=<model>` (bench_launch.py; the app strips
inherited `CMUX_TUI_*` names and passes this knob to its daemon as `CMUX_TUI_TERMINAL_HOST_MODEL`,
DaemonDiagnosticKnobs), then:

  light    the start session plus 3 new workspaces: terminal processes and RSS per terminal;
  stress   the STRESS session (perf-stress-session.py: 60 workspaces, 12-14 panes x 6 tabs, 10 busy
           terminals): the same numbers, and the busy terminals keep printing;
  close    Cmd-W of a terminal tab (the app's closeTab): its shell ends once the daemon's reap grace
           (30 s) has passed;
  reopen   Reopen Last Closed Item (history.reopen): the terminal comes back with its screen;
  paste    a 256 KiB paste (the app's terminalPaste, from the pasteboard; its confirmation answered with
           Allow) into `head -c N | wc -c`: the program gets every byte;
  holder   SIGKILL of the holder while the app runs (holder model only): every shell lives, the busy
           terminals keep printing, input and new terminals work, a new holder runs;
  relaunch quit the app (quitKeepSessions) and launch it again on its saved session: every terminal is back
           with its screen.

Terminal state is read through the tag daemon's own socket (`--socket` of its headless cmux-tui, the
commands the cmux-tui tests use: read-screen, send, terminal-resources, list-workspaces); app actions
go through the app's debug socket (`action.run`). Prints `DOGFOOD-STEP {json}` per step and
`DOGFOOD-COST {json}` per measured shape; exits 1 when a step failed.

  nx-remote --host mac26 --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/holder-dogfood.py --app "$NX_APP" --model holder --out "$NX_ARTIFACTS"

Signals only processes the tag started (the holder by its exact pid, found as the parent of the tag
daemon's shells).
"""
import argparse, importlib.util, json, os, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

PASTE_BYTES = 256 * 1024
# The app's actions these steps run, by exact id (TabActionCatalog, HistoryActionCatalog, TerminalActionCatalog).
# A fuzzy match picked closeOtherTabsInPane for Cmd-W and pasteLastScreenshot for the paste (sorted first).
CLOSE_TAB, REOPEN_CLOSED, TERMINAL_PASTE = "closeTab", "history.reopen", "terminalPaste"
# A closed tab detaches its terminal; the app's daemon ends it after this grace (DaemonLauncher
# terminalReapGraceSeconds, cmux-tui spec set-terminal-keep), so the shell's end is awaited past it.
REAP_GRACE_S = 30
SHELL_END_S = REAP_GRACE_S + 20
# The app's confirmation for a paste with line breaks while bracketed paste is off (TerminalClipboardRequests).
PASTE_DIALOG = "cmux.dialog.terminalClipboard"


def load_stress():
    path = os.path.join(HERE, "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def emit(kind, record):
    print(f"{kind} {json.dumps(record, sort_keys=True)}", flush=True)


def wait(predicate, seconds, step=0.2):
    """Bounded poll of app or daemon state from a test script."""
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = predicate()
        except Exception as error:  # the app or daemon may not answer yet
            last = None
            _ = error
        if last:
            return last
        time.sleep(step)  # test script: the poll interval
    return last


class Daemon:
    """The tag's headless cmux-tui: its pid and its control socket (JSON lines)."""

    def __init__(self, app_path):
        self.app_path = app_path
        self.pid, self.socket = self.find()

    def find(self):
        tui = os.path.join(os.path.realpath(self.app_path), "Contents/Resources/bin/cmux-tui")
        for pid, command in TagTeardown(self.app_path).processes():
            if command.startswith(tui + " --headless"):
                words = command.split()
                if "--socket" in words:
                    return pid, words[words.index("--socket") + 1]
        raise SystemExit("holder-dogfood: the tag's cmux-tui daemon is not running")

    def call(self, cmd, timeout=60, **params):
        body = dict(params, cmd=cmd, id=1)
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(self.socket)
        conn.sendall((json.dumps(body) + "\n").encode())
        reader = conn.makefile("r")
        try:
            for line in reader:
                reply = json.loads(line)
                if reply.get("id") == 1 and "ok" in reply:
                    if not reply["ok"]:
                        raise RuntimeError(f"{cmd}: {reply.get('error')}")
                    return reply.get("data")
        finally:
            conn.close()
        raise RuntimeError(f"{cmd}: the daemon closed the socket")

    def surfaces(self):
        """Every terminal surface the daemon shows, by walking list-workspaces."""
        tree = self.call("list-workspaces")
        found = []

        def walk(node):
            if isinstance(node, dict):
                kind = node.get("kind")
                surface = node.get("surface") if isinstance(node.get("surface"), int) else None
                if surface is None and isinstance(node.get("id"), int) and kind in ("terminal", "pty"):
                    surface = node["id"]
                if surface is not None and kind in (None, "terminal", "pty"):
                    found.append(surface)
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(tree)
        return sorted(set(found))

    def screen(self, surface):
        return (self.call("read-screen", surface=surface) or {}).get("text", "")

    def shells(self, surfaces):
        resources = self.call("terminal-resources", surfaces=surfaces)
        return {t.get("surface"): t.get("pid") for t in (resources or {}).get("terminals", [])}


def processes():
    """pid -> (ppid, rss KiB, command) of every process (same-host accounting; no signals)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit():
            table[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    return table


def terminal_processes(daemon, surfaces=None):
    """The daemon's terminal processes, found as the parents of its terminals' shells (the pids
    terminal-resources reports): hosts (`__terminal-host`) and holders (cmux-holder, or the holder
    built into cmux-tui-host). Not by parent pid: a holder detaches from the daemon (it outlives a
    daemon crash), so its parent is launchd. A shell whose parent is the daemon has no such process."""
    table = processes()
    if surfaces is None:
        surfaces = daemon.surfaces()
    parents = {table[pid][0] for pid in daemon.shells(surfaces).values() if pid in table}
    hosts, holders = [], []
    for pid in sorted(parents):
        if pid == daemon.pid or pid not in table:
            continue
        _, rss, command = table[pid]
        if "__terminal-host" in command:
            hosts.append((pid, rss))
        elif "cmux-holder" in command or "__holder" in command or "cmux-tui-host" in command:
            holders.append((pid, rss, command.split()[0]))
    daemon_rss = table.get(daemon.pid, (0, 0, ""))[1]
    return hosts, holders, daemon_rss


def cost(shape, model, daemon, surfaces):
    hosts, holders, daemon_rss = terminal_processes(daemon, surfaces)
    n = max(1, len(surfaces))
    terminal_rss = sum(rss for _, rss in hosts) + sum(rss for _, rss, _ in holders)
    record = {
        "shape": shape, "model": model, "terminals": len(surfaces),
        "host_processes": len(hosts), "holder_processes": len(holders),
        "terminal_processes_per_terminal": round((len(hosts) + len(holders)) / n, 3),
        "terminal_process_rss_kb": terminal_rss,
        "terminal_process_rss_kb_per_terminal": round(terminal_rss / n, 1),
        "daemon_rss_kb": daemon_rss,
        "daemon_rss_kb_per_terminal": round(daemon_rss / n, 1),
        "holder_executable": holders[0][2] if holders else None,
    }
    emit("DOGFOOD-COST", record)
    return record


class Dogfood:
    def __init__(self, opts):
        self.opts = opts
        self.failed = []
        self.app = None
        self.daemon = None
        self.actions = []
        self.state_dir = os.path.join(opts.out or tempfile.mkdtemp(prefix="holder-dogfood-"), "tui-state")
        shutil.rmtree(self.state_dir, ignore_errors=True)
        os.makedirs(self.state_dir)

    # -- plumbing ------------------------------------------------------------------------------
    def step(self, name, ok, **detail):
        record = {"step": name, "ok": bool(ok), "model": self.opts.model, **detail}
        emit("DOGFOOD-STEP", record)
        if not ok:
            self.failed.append(name)
        return ok

    def launch(self, fresh=True):
        # Each model's run gets its own daemon state (sessions, terminal hosts): the run before it
        # (or another step's run of this tag) must not restore its terminals into this one's count.
        # A relaunch within the run keeps it (`fresh=False`: BenchApp leaves the tag's saved session).
        env = launch_env(self.opts.model, self.state_dir)
        self.app = BenchApp(self.opts.app, out=self.opts.out, env=env, teardown=False, fresh_state=fresh)
        self.app.launch()
        self.daemon = wait(lambda: Daemon(self.opts.app), 60)
        if not isinstance(self.daemon, Daemon):
            raise SystemExit("holder-dogfood: no daemon after the launch")
        listed = self.app.rpc("action.list")
        rows = listed.get("actions") if isinstance(listed, dict) else listed
        self.actions = sorted({row.get("id") for row in rows or [] if isinstance(row, dict) and row.get("id")})

    def action(self, action_id):
        """`action_id` when the app lists it, else None (the step then fails and names it)."""
        return action_id if action_id in self.actions else None

    def run_action(self, action, **params):
        return self.app.rpc("action.run", {"action": action, "focus": True, **params})

    def alive(self, pid):
        try:
            os.kill(pid, 0)  # probe only: a shell the tag's daemon started
            return True
        except (ProcessLookupError, TypeError):
            return False

    def busy(self, surfaces, seconds=1.5):
        """Surfaces whose screen changed within `seconds` (printing terminals)."""
        first = {s: self.daemon.screen(s) for s in surfaces}
        time.sleep(seconds)  # test script: the window in which a busy terminal prints
        return [s for s in surfaces if self.daemon.screen(s) != first[s]]

    def new_terminal(self, name, argv):
        created = self.daemon.call("run", argv=argv, new_workspace=True, name=name, cols=100, rows=30)
        return created["surface"], created.get("terminal_id")

    def screen_has(self, surface, text, seconds=20):
        return wait(lambda: text in self.daemon.screen(surface), seconds)

    # -- steps ---------------------------------------------------------------------------------
    def light(self):
        """The light shape; in the holder model also whether its terminals run on a holder at all (an app
        whose daemon never got the model runs every terminal on a host: the run measures nothing new)."""
        shown = 0
        for index in range(3):
            surface, _ = self.new_terminal(f"light-{index}", ["/bin/sh", "-c", f"echo light-{index}; exec cat"])
            shown += bool(self.screen_has(surface, f"light-{index}"))
        surfaces = self.daemon.surfaces()
        record = cost("light", self.opts.model, self.daemon, surfaces)
        self.step("light", shown == 3 and record["terminals"] >= 3, terminals=record["terminals"], shown=shown)
        if self.opts.model == "holder":
            self.step("holder-model", record["holder_processes"] >= 1,
                      holder_processes=record["holder_processes"], host_processes=record["host_processes"])

    def stress(self):
        stress = load_stress()
        try:
            summary = stress.Stress(self.app.rpc).build()
            self.step("stress-shape", True)
        except stress.StressShapeError as error:
            # The session the builder made is measured anyway (both models get the same builder);
            # the step reports the shape it missed.
            summary = {"shape_error": str(error)[:2000]}
            self.step("stress-shape", False, error=str(error)[:2000])
        emit("STRESS-SESSION", summary)
        time.sleep(2)  # test script: the busy terminals start printing
        surfaces = self.daemon.surfaces()
        cost("stress", self.opts.model, self.daemon, surfaces)
        printing = self.busy(surfaces)
        self.step("stress-busy", len(printing) >= 10, terminals=len(surfaces), printing=len(printing))
        return surfaces, printing

    def close_and_reopen(self):
        surface, _ = self.new_terminal("dogfood-close", ["/bin/sh", "-c", "echo close-me-marker; exec cat"])
        self.screen_has(surface, "close-me-marker")
        shell = self.daemon.shells([surface]).get(surface)
        tab = wait(lambda: find_tab(self.app.rpc("snapshot.get"), "dogfood-close"), 20)
        close = self.action(CLOSE_TAB)
        reply = None
        if tab and close:
            self.run_action("tab.focus", target=f"tab:{tab}")
            reply = self.run_action(close, target=f"tab:{tab}")
        else:
            self.daemon.call("close-surface", surface=surface)
        start = time.monotonic()
        ended = wait(lambda: not self.alive(shell), SHELL_END_S)
        self.step("cmd-w", bool(ended) and bool(tab and close), action=close, tab=tab, shell=shell,
                  ended_after_s=round(time.monotonic() - start, 1), reply=refusal(reply))
        reopen = self.action(REOPEN_CLOSED)
        before = set(self.daemon.surfaces())
        reply = self.run_action(reopen) if reopen else None
        back = wait(lambda: [s for s in self.daemon.surfaces() if s not in before], 20) or []
        shown = bool(back) and bool(self.screen_has(back[0], "close-me-marker", 20))
        self.step("reopen-closed", shown and bool(reopen), action=reopen, surfaces=back, reply=refusal(reply))
        return back[0] if back else None

    def allow_paste(self, seconds=10):
        """Presses Allow on the app's paste confirmation (a paste with line breaks while bracketed paste is
        off asks first, as a person's does); True once pressed, None when none showed in `seconds`."""
        def press():
            listed = self.app.rpc("debug.dialog", {})
            dialog = next((d for d in (listed or {}).get("dialogs") or [] if isinstance(listed, dict)
                           and d.get("identifier") == PASTE_DIALOG and d.get("visible")), None)
            if dialog is None:
                return None
            return bool((self.app.rpc("debug.dialog", {"id": dialog["id"], "press": "allow"}) or {}).get("pressed"))
        return wait(press, seconds)

    def paste(self):
        surface, _ = self.new_terminal(
            "dogfood-paste", ["/bin/sh", "-c", f"stty -echo; echo paste-ready; head -c {PASTE_BYTES} | wc -c; exec cat"])
        self.screen_has(surface, "paste-ready")
        data = paste_payload()
        subprocess.run(["pbcopy"], input=data.encode(), check=True)
        tab = wait(lambda: find_tab(self.app.rpc("snapshot.get"), "dogfood-paste"), 20)
        pane = find_pane(self.app.rpc("snapshot.get"), "dogfood-paste")
        paste = self.action(TERMINAL_PASTE)
        if tab:
            self.run_action("tab.focus", target=f"tab:{tab}")
        reply = allowed = None
        if paste:
            # terminalPaste takes a pane target only (TerminalActionCatalog: targets [.pane]); a tab target
            # is refused before the handler runs (ControlRouter+Validation wrongTargetKind).
            reply = self.run_action(paste, **({"target": f"pane:{pane}"} if pane else {}))
            allowed = self.allow_paste()
        got = self.screen_has(surface, str(PASTE_BYTES), 60)
        self.step("paste-256k", bool(got) and bool(paste), action=paste, tab=tab, pane=pane, reply=refusal(reply),
                  confirmed=allowed, screen_tail=self.daemon.screen(surface)[-200:])

    def kill_holder(self, printing):
        hosts, holders, _ = terminal_processes(self.daemon)
        if self.opts.model != "holder":
            return self.step("holder-kill", True, skipped="hosts model")
        if not holders:
            return self.step("holder-kill", False, error="no holder process")
        surfaces = self.daemon.surfaces()
        shells = self.daemon.shells(surfaces)
        old = holders[0][0]
        os.kill(old, signal.SIGKILL)  # the holder this tag's daemon started, by its exact pid
        lived = all(self.alive(pid) for pid in shells.values() if pid)
        still = self.busy(printing, seconds=2.0)
        echo, _ = self.new_terminal("dogfood-after-kill", ["/bin/cat"])
        self.daemon.call("send", surface=echo, text="typed-after-holder-kill\n")
        typed = self.screen_has(echo, "typed-after-holder-kill")
        _, holders_after, _ = terminal_processes(self.daemon)
        new = [pid for pid, _, _ in holders_after if pid != old]
        self.step("holder-kill", lived and len(still) >= len(printing) - 1 and bool(typed) and bool(new),
                  shells=len(shells), all_shells_alive=lived, printing_before=len(printing),
                  printing_after=len(still), typed=bool(typed), new_holder=new[:1])

    def relaunch(self, markers):
        # Quit and keep the sessions (the terminals and the daemon run on; DebugQuit's quitWith). `debug.quit {}`
        # only reports the quit sheet: the app ran on and the relaunch stopped at tag-in-use on every run.
        reply = self.app.rpc("action.run", {"action": QUIT_KEEPING_SESSIONS, "origin": "script"}, timeout=20)
        # The app may exit before it answers (the socket drops: `unreachable`); only the app's own refusal fails.
        quit_error = None if isinstance(reply, dict) and reply.get("unreachable") else refusal(reply)
        # A clean quit exits 0 by itself; a crash ends with a signal (a negative status) or another nonzero code.
        try:
            status = self.app.process.wait(30)
        except Exception:  # noqa: BLE001 - the app this script started, by its pid
            status = None
            self.app.process.terminate()
            self.app.process.wait(15)
        exited = status == 0
        daemon_pid = self.daemon.pid
        self.launch(fresh=False)
        same_daemon = self.daemon.pid == daemon_pid
        found = {marker: any(marker in self.daemon.screen(s) for s in self.daemon.surfaces()) for marker in markers}
        # Kept sessions: the app quit (no refusal) and its daemon ran on, so the relaunch attached to the same one.
        self.step("quit-relaunch", quit_error is None and exited and same_daemon and all(found.values()),
                  same_daemon=same_daemon, quit_status=status, markers=found, quit_reply=quit_error)

    def run(self):
        teardown = TagTeardown(self.opts.app)
        teardown.install()
        try:
            self.launch()
            emit("DOGFOOD-ACTIONS", {"close": self.action(CLOSE_TAB), "reopen": self.action(REOPEN_CLOSED),
                                     "paste": self.action(TERMINAL_PASTE), "count": len(self.actions)})
            self.step("launch", True, state_dir=self.state_dir)
            self.light()
            _, printing = self.stress()
            self.close_and_reopen()
            self.paste()
            self.kill_holder(printing)
            self.relaunch(["light-0", "close-me-marker", "typed-after-holder-kill" if self.opts.model == "holder" else "light-1"])
            hangs = self.app.rpc("debug.hangs")
            emit("DOGFOOD-HANGS", hangs if isinstance(hangs, dict) else {"hangs": hangs})
        finally:
            try:
                if self.app:
                    self.app.rpc("action.run", {"action": "quitEndSessions"}, timeout=20)
            except Exception:  # noqa: BLE001 - teardown below ends the rest
                pass
            teardown.end()
        return 1 if self.failed else 0


# Quit, leaving the terminals and the daemon running (DebugQuit `quitWith.keep_sessions`).
QUIT_KEEPING_SESSIONS = "quitKeepSessions"


def launch_env(model, state_dir):
    """The app's launch environment for `model`: the app knob for the daemon's terminal host model (the app
    unsets an inherited CMUX_TUI_TERMINAL_HOST_MODEL, LaunchIdentity.inheritedKeys) and the daemon state."""
    return {"CMUX_NEXT_TUI_TERMINAL_HOST_MODEL": model, "CMUX_TUI_STATE_DIR": state_dir}


def refusal(reply):
    """The app's error of an action.run reply (short), or None when it ran."""
    error = reply.get("error") if isinstance(reply, dict) else None
    return str(error)[:200] if error else None


def paste_payload():
    """PASTE_BYTES of 100-byte lines, the last one cut short and still ending in a newline: the shell's tty is
    canonical (`stty -echo` only), so `head -c` gets a line only at its newline, and bytes after the last
    one would wait in the line buffer (262144 is not a multiple of 100: 44 bytes)."""
    line = ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" * 2)[:99] + "\n"
    return (line * (PASTE_BYTES // len(line) + 1))[:PASTE_BYTES - 1] + "\n"


def find_pane(snapshot, workspace_name):
    """The app pane id of the first pane in the workspace named `workspace_name`, as `find_tab`."""
    topology = (snapshot or {}).get("topology") or {} if isinstance(snapshot, dict) else {}
    for workspace in topology.get("workspaces") or []:
        if workspace_name in {str(v) for v in workspace.values() if isinstance(v, str)}:
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if pane.get("id"):
                        return pane["id"]
    return None


def find_tab(snapshot, workspace_name):
    """The app tab id of the first tab in the workspace named `workspace_name` (the daemon's `run`
    makes one workspace per terminal, named), from `snapshot.get`'s topology."""
    topology = (snapshot or {}).get("topology") or {} if isinstance(snapshot, dict) else {}
    for workspace in topology.get("workspaces") or []:
        names = {str(v) for v in workspace.values() if isinstance(v, str)}
        if workspace_name not in names:
            continue
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id"):
                        return tab["id"]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--model", choices=("holder", "hosts"), default="holder")
    parser.add_argument("--out", default=None)
    opts = parser.parse_args()
    return Dogfood(opts).run()


if __name__ == "__main__":
    sys.exit(main())
