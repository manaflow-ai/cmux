"""Launch, drive and stop a tagged cmux NEXT app for perf100 (macOS, GUI host only).

The app runs on a scratch HOME, TMPDIR and cmux.json (updates off, mock keychain, no
activation), launched through LaunchServices (`open -n -g`) so WebKit processes count as the
app's. It is driven over its control socket only (action.run and debug.* methods; DEBUG
builds, which fleet tagged builds are). It never takes focus and sends no real input.

Teardown: `quitEndSessions` over the socket, then a kqueue wait for the app's exit. In an
nx-remote job, `$NX_APP_STOP` then stops what is left (the job never signals a process
itself). Elsewhere (a cmux-ci bench worker, which xbench uses the same way), bench_memory's
end_bundle ends the bundle's leftover processes.
"""
from __future__ import annotations

import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import procstat

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))
import bench_memory as bm  # noqa: E402  (the cmux-next benches' socket client and process helpers)


class Rpc:
    """One JSON Lines connection to the app's control socket."""

    def __init__(self, path: str, timeout: float = 60):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def call(self, method: str, params: dict | None = None) -> dict:
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("app socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid:
                return msg

    def result(self, method: str, params: dict | None = None) -> dict:
        msg = self.call(method, params)
        return msg.get("result") or {}

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def wait_exit(pid: int, timeout: float) -> bool:
    """kqueue NOTE_EXIT on `pid`: True once it exited (no polling)."""
    try:
        kq = select.kqueue()
    except AttributeError:
        return False
    try:
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                              fflags=select.KQ_NOTE_EXIT)
        try:
            got = kq.control([event], 1, timeout)
        except ProcessLookupError:
            return True
        return bool(got)
    finally:
        kq.close()


class App:
    """One launched instance of the bundle on its own scratch profile."""

    def __init__(self, bundle: str, scratch: str | None = None, allow_agents: bool = False, extra_env=None):
        self.bundle = os.path.realpath(bundle)
        self.scratch = scratch or tempfile.mkdtemp(prefix="p100app-", dir="/tmp")
        self.home = os.path.join(self.scratch, "home")
        self.tmp = os.path.join(self.scratch, "tmp")
        os.makedirs(os.path.join(self.home, "Library"), exist_ok=True)
        os.makedirs(self.tmp, exist_ok=True)
        # Empty shell profiles: zsh's new-user menu would otherwise wait for (and eat) typed keys.
        for name in (".zshrc", ".zprofile", ".bashrc", ".profile", ".hushlogin"):
            path = os.path.join(self.home, name)
            if not os.path.exists(path):
                open(path, "w").close()
        self.config = os.path.join(self.scratch, "cmux.json")
        if not os.path.exists(self.config):
            with open(self.config, "w") as handle:
                json.dump({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, handle)
        self.allow_agents = allow_agents
        self.extra_env = extra_env or {}
        self.pid = None
        self.socket = None
        self.rpc = None
        self.hosts_seen: set[int] = set()  # terminal hosts outlive a daemon; a relaunch adopts them
        self.owned: set[int] = set()  # every process discover() attributed to this instance
        self.launched_at = None
        binary_dir = os.path.join(self.bundle, "Contents/MacOS")
        self.binary = os.path.join(binary_dir, sorted(os.listdir(binary_dir))[0])
        self.cli = os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tui = os.path.join(self.bundle, "Contents/Resources/bin/cmux-tui")

    def env(self) -> dict:
        env = {"HOME": self.home, "CFFIXED_USER_HOME": self.home, "USER": os.environ.get("USER", ""),
               "TMPDIR": self.tmp + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_CONFIG_FILE": self.config, "CMUX_MOCK_KEYCHAIN": "1",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "NX_REMOTE": "1", "ACPMUX_LOGIN_ENV": "0"}
        if not self.allow_agents:
            env["ACPMUX_AGENT_LAUNCH"] = "deny"
        # nx-remote attributes processes to the job by these (build-host/README.md, PTYs).
        for key in ("NX_JOB_ID", "NX_JOB_DIR"):
            if os.environ.get(key):
                env[key] = os.environ[key]
        env.update(self.extra_env)
        return env

    def launch(self, timeout: float = 120) -> float:
        """Launches; returns ms from `open` to the control socket answering `identify`."""
        # Every process of this bundle must be this run's (the sweep outside nx-remote ends them all);
        # a relaunch finds the daemons and hosts its own quit kept.
        self.discover()
        running = sorted(bm.bundle_pids(self.bundle) - self.owned)
        if running:
            raise RuntimeError(f"perf100: processes of {self.bundle} already run ({running[:20]}); stop them first")
        argv = ["open", "-n", "-g"] + [x for k, v in self.env().items() for x in ("--env", f"{k}={v}")]
        self.launched_at = time.monotonic()
        subprocess.run(argv + ["-a", self.bundle], check=True, timeout=60)
        deadline = self.launched_at + timeout
        state = os.path.join(self.home, ".local/state/cmux")
        while time.monotonic() < deadline:
            if self.pid is None:
                self.pid = next((p for p, _pp, cmd in procstat.process_table() if bm.is_binary(cmd, self.binary)), None)
            if self.pid:
                dirs = [d for d in (state, self.tmp, "/tmp") if os.path.isdir(d)]
                path = bm.control_socket(self.bundle, self.pid, dirs)
                if path:
                    self.socket = path
                    self.rpc = Rpc(path)
                    self.actions = bm.App(self.bundle, path)
                    return (time.monotonic() - self.launched_at) * 1000
            time.sleep(0.05)  # bench: waiting for the launched app's control socket (bounded)
        raise RuntimeError(f"perf100: the app opened no control socket within {timeout} s")

    # -- driving

    def act(self, action: str, focus: bool = False, **args) -> dict:
        reply = self.actions.action(action, focus=focus, **args)
        if reply.get("error"):
            raise RuntimeError(f"{action}: {reply['error']}")
        return reply

    def topology(self) -> dict:
        return self.rpc.result("snapshot.get").get("topology") or {}

    def workspace_count(self) -> int:
        return len(self.topology().get("workspaces", []))

    def focused_tab(self) -> dict | None:
        topo = self.topology()
        focus = topo.get("focus") or {}
        for ws in topo.get("workspaces", []):
            for screen in ws.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if tab.get("id") == focus.get("tab") or (pane.get("id") == focus.get("pane") and tab.get("selected")):
                            return tab
        return None

    def daemon_socket(self) -> str | None:
        """The control socket of this app's cmux-tui daemon (its `--socket` argument)."""
        prefix = os.path.join(self.bundle, "Contents/Resources/bin/cmux-tui") + " --headless --session cmux-app-"
        alt = prefix.removeprefix("/private")
        for _pid, _ppid, cmd in procstat.process_table():
            if cmd.startswith((prefix, alt)) and " --socket " in cmd:
                return cmd.split(" --socket ", 1)[1].split()[0]
        return None

    def send_text(self, text: str, tab_id: str | None = None) -> str | None:
        """Types `text` into a terminal tab (the focused one by default) through the app's daemon:
        `send` on its control socket, as the app's own input path does. None on success, else why."""
        import headless
        topo_tabs = self.tabs()
        tab_id = tab_id or (self.topology().get("focus") or {}).get("tab")
        tab = next((t for t in topo_tabs if t.get("id") == tab_id), None)
        if tab is None or tab.get("kind") != "terminal" or tab.get("surface") is None:
            kinds = ", ".join(f"{t.get('id')}:{t.get('kind')}" for t in topo_tabs[:8])
            return f"tab {tab_id} is not a terminal in the focused workspace (tabs: {kinds})"
        path = self.daemon_socket()
        if not path:
            return "no cmux-tui daemon of this app"
        try:
            conn = headless.Conn(path, timeout=30)
            try:
                reply = conn.call("send", surface=int(tab["surface"]), text=text)
            finally:
                conn.close()
        except (OSError, ConnectionError, ValueError) as error:
            return repr(error)
        return None if reply.get("ok") else str(reply.get("error"))[:300]

    def tabs(self, kind: str | None = None, workspace: str | None = None) -> list[dict]:
        topo = self.topology()
        ws_id = workspace or (topo.get("focus") or {}).get("workspace")
        out = []
        for ws in topo.get("workspaces", []):
            if ws_id and ws.get("id") != ws_id:
                continue
            for screen in ws.get("screens", []):
                for pane in screen.get("panes", []):
                    out.extend(t for t in pane.get("tabs", []) if kind is None or t.get("kind") == kind)
        return out

    def focus_tab(self, tab_id: str) -> dict:
        return self.rpc.call("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": tab_id}})

    def focus_terminal(self) -> str | None:
        """Shows the focused workspace's first terminal tab; returns its id."""
        terminals = self.tabs("terminal")
        if not terminals:
            return None
        self.focus_tab(terminals[0]["id"])
        return terminals[0]["id"]

    def _cli_env(self) -> dict:
        return {"HOME": self.home, "TMPDIR": self.tmp + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "USER": os.environ.get("USER", "")}

    def read_text(self) -> str:
        """The focused terminal mirror's viewport text, as the view renders it (debug.surfaces text)."""
        report = self.rpc.result("debug.surfaces", {"text": True})
        panes = [p for w in report.get("windows", []) for p in w.get("panes", [])]
        focused = [p for p in panes if p.get("focused") and isinstance(p.get("text"), str)]
        return (focused or [p for p in panes if isinstance(p.get("text"), str)] or [{"text": ""}])[0]["text"]

    def new_workspace(self) -> str | None:
        made = self.act("workspace.newAtBottom")
        created = [c for c in made.get("created", []) if str(c).startswith("ws_")]
        self.act("workspace.selectLast", focus=True)
        return created[0] if created else None

    def key_echo_ms(self, marker: str, timeout: float = 30) -> float | None:
        """Types `marker` with debug.key into the focused terminal; ms until surface.read_text shows it.

        The keys go through the app's key path (no real input). Reads poll the socket: the
        result is an upper bound by one round trip."""
        t0 = time.monotonic()
        for ch in marker:
            self.rpc.call("debug.key", {"key": ch})
        deadline = t0 + timeout
        while time.monotonic() < deadline:
            if marker in self.read_text():
                ms = (time.monotonic() - t0) * 1000
                self.rpc.call("debug.key", {"key": "u", "modifiers": ["ctrl"]})
                return ms
            time.sleep(0.002)  # bench: next read of the screen (bounded by the deadline)
        return None

    def wait_first_terminal(self, timeout: float = 60, mark: str = "first_terminal_surface_created") -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            launch = self.rpc.result("debug.timings").get("launch_ms_since_process_start", {})
            if mark in launch:
                return launch
            time.sleep(0.01)  # bench: waiting for the first terminal (bounded)
        return {}

    def acpmux_socket(self) -> str:
        return bm.FakeChats.acpmux_socket(self.bundle)

    # -- processes

    def discover(self) -> dict[int, str]:
        """Every process of this instance: the bundle's, the WebKit processes the app is responsible
        for, the terminal hosts (they run from a copy under the scratch HOME) and their children."""
        table = procstat.process_table()
        roots_text = (self.bundle + "/", self.bundle.removeprefix("/private") + "/", self.scratch)
        out: dict[int, str] = {}
        hosts = set()
        for pid, _ppid, cmd in table:
            if "replay_agent.py" in cmd and self.scratch in cmd:
                out[pid] = "agent-standin"
            elif "__terminal-host" in cmd and (self.scratch in cmd or self.bundle in cmd or
                                               (self.pid and re.search(rf"@{self.pid}\b", cmd))):
                out[pid] = "terminal-host"
                hosts.add(pid)
            elif cmd.startswith(roots_text) or (self.bundle in cmd and "/Contents/" in cmd):
                out[pid] = _kind(cmd, self.bundle)
            elif self.pid and "com.apple.WebKit." in cmd and procstat.responsible_pid(pid) == self.pid:
                out[pid] = bm.kind_of(cmd, self.bundle)
        # Terminal hosts that name their daemon by pid.
        daemons = {p for p, k in out.items() if k.startswith("tui-daemon")}
        for pid, _ppid, cmd in table:
            if "__terminal-host" in cmd and pid not in out and any(re.search(rf"@{d}\b", cmd) for d in daemons):
                out[pid] = "terminal-host"
                hosts.add(pid)
        commands = {pid: cmd for pid, _ppid, cmd in table}
        for pid in self.hosts_seen:
            if pid not in out and "__terminal-host" in commands.get(pid, ""):
                out[pid] = "terminal-host"
                hosts.add(pid)
        self.hosts_seen |= hosts
        self.owned |= set(out)
        for pid in procstat.descendants(hosts, table) - hosts:
            if pid not in out:
                cmd = commands.get(pid, "")
                out[pid] = "workload:" + (os.path.basename(cmd.split()[0])[:24] if cmd else "?")
        return out

    def stop(self, end_sessions: bool = True, timeout: float = 60) -> float | None:
        """Quits over the socket; returns ms until the app process exited (None: it did not)."""
        if self.pid is None:
            return None
        t0 = time.monotonic()
        try:
            self.actions.action("quitEndSessions" if end_sessions else "quitKeepSessions")
        except Exception:  # noqa: BLE001 - the app may close the socket while it quits
            pass
        if self.rpc:
            self.rpc.close()
            self.rpc = None
        exited = wait_exit(self.pid, timeout)
        ms = (time.monotonic() - t0) * 1000 if exited else None
        self.pid = None
        return ms

    def sweep(self):
        """Stops what this instance left: $NX_APP_STOP in an nx-remote job, else the bundle's processes."""
        if self.launched_at is None:
            return
        if os.environ.get("NX_APP_STOP"):
            subprocess.run([os.environ["NX_APP_STOP"]], timeout=180)
        else:
            bm.end_bundle(self.bundle)

    def cleanup(self):
        shutil.rmtree(self.scratch, ignore_errors=True)


def _kind(cmd: str, bundle: str) -> str:
    rel = bm.in_bundle(cmd, bundle)
    if rel is None:
        # A copy outside the bundle (terminal hosts run from a host-exe copy under HOME).
        rel = cmd
    if "/bin/acpmux" in rel:
        rest = rel.split("/bin/acpmux", 1)[1].split()
        if rest[:2] == ["daemon", "run"]:
            return "acpmux-daemon"
        if rest[:1] in (["send"], ["new"], ["wait"]):
            return "acpmux-client"
        return "acpmux-" + (rest[0] if rest else "agent")
    if "/bin/cmux " in rel and "/bin/cmux-tui" not in rel:
        if " mcp " in rel or rel.rstrip().endswith(" mcp serve"):
            return "cmux-mcp"
        if any(word in rel for word in (" --socket ", " --app-socket ", " acp ", " send ")):
            return "acpmux-client"  # the harness's own CLI calls (group harness)
    return bm.kind_of(cmd, bundle)
