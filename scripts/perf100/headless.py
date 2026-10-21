"""perf100 headless scenarios: the cmux-tui daemon and the acpmux daemon with no app.

Each scenario starts its own daemon on a fresh scratch root (durable state on the local disk,
so the journal and fsync cost what they cost), drives it over its own socket or CLI, and ends
it through its own shutdown command. It never signals a process it did not start.

  tui    S0 idle terminals and idle agent TUIs, S1 terminal flood (1 then 10 at once),
         S3 scale (workspaces x terminals), S4 cold start, daemon restart that adopts the
         S3 terminals, shutdown.
  acpmux S2 agent streaming: N sessions on the replay agent stream a recorded fixture at
         once; token-to-client latency through `acpmux send`.
"""
from __future__ import annotations

import base64
import json
import re
import os
import random
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import procstat
import runlib

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")


class Conn:
    """One JSON-lines control connection to a cmux-tui daemon."""

    def __init__(self, path: str, timeout: float = 120):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send_line(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("control socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.send_line({"id": rid, "cmd": cmd, **params})
        while True:
            msg = self.read_line()
            if msg.get("id") == rid and "ok" in msg:
                return msg


def must(resp, what):
    if not resp.get("ok"):
        raise RuntimeError(f"{what} failed: {resp.get('error')!r} {resp.get('error_code', '')}")
    return resp.get("data") or {}


class TuiDaemon:
    def __init__(self, binary: str, root: str):
        self.binary = binary
        self.root = root
        self.sock = os.path.join(root, "s.sock")
        self.state = os.path.join(root, "state")
        self.home = os.path.join(root, "home")
        self.session = f"perf100-{os.getpid()}"
        self.proc = None
        self.hosts_seen: set[int] = set()  # hosts outlive their daemon; a restarted daemon adopts them
        for path in (self.state, self.home):
            os.makedirs(path, exist_ok=True)
        self.env = dict(os.environ, HOME=self.home, XDG_CONFIG_HOME=os.path.join(self.home, ".config"),
                        XDG_STATE_HOME=os.path.join(self.home, ".local/state"),
                        XDG_DATA_HOME=os.path.join(self.home, ".local/share"),
                        XDG_CACHE_HOME=os.path.join(self.home, ".cache"),
                        CMUX_TUI_CONFIG=os.path.join(root, "config.json"), PS1="$ ")
        self.log = open(os.path.join(root, "daemon.log"), "a")

    def start(self) -> float:
        """Starts the daemon; returns ms from spawn to its first `identify` answer."""
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        argv = [self.binary, "--headless", "--session", self.session, "--socket", self.sock, "--state", self.state]
        t0 = time.monotonic()
        self.proc = subprocess.Popen(argv, stdout=self.log, stderr=subprocess.STDOUT, env=self.env,
                                     start_new_session=True)
        deadline = t0 + 60
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"cmux-tui exited {self.proc.returncode}; see {self.root}/daemon.log")
            if os.path.exists(self.sock):
                try:
                    conn = Conn(self.sock, timeout=10)
                    self.ident = must(conn.call("identify"), "identify")
                    conn.close()
                    return (time.monotonic() - t0) * 1000
                except (OSError, ConnectionError, RuntimeError, ValueError):
                    pass
            time.sleep(0.005)  # bench: waiting for the new daemon's socket (bounded by the deadline)
        raise RuntimeError("cmux-tui socket did not answer within 60 s")

    def shutdown(self, end_terminals: bool) -> float:
        """`shutdown-daemon` on its own socket; returns ms until the daemon process exited."""
        t0 = time.monotonic()
        conn = Conn(self.sock, timeout=600)
        ident = must(conn.call("identify"), "identify")
        conn.call("shutdown-daemon", pid=ident["pid"],
                  generation=ident.get("generation") or ident.get("boot_generation") or "", end_terminals=end_terminals)
        conn.close()
        self.proc.wait(timeout=600)
        return (time.monotonic() - t0) * 1000

    def reap(self):
        """Last resort for a daemon this run started that did not stop: SIGKILL its own Popen."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=30)

    def wait_hosts_gone(self, seconds: float) -> list[int]:
        """Terminal hosts of this run still alive after up to `seconds` (they exit after the daemon)."""
        deadline = time.monotonic() + seconds
        while True:
            left = [p for p, k in self.discover().items() if k == "terminal-host"]
            if not left or time.monotonic() >= deadline:
                return left
            time.sleep(0.2)  # bench: bounded wait for the hosts' own exit

    def discover(self) -> dict[int, str]:
        """The daemon, its terminal hosts (also those that left its process tree) and their children."""
        table = procstat.process_table()
        roots = {self.proc.pid} if self.proc and self.proc.poll() is None else set()
        commands = {pid: cmd for pid, _ppid, cmd in table}
        for pid, _ppid, cmd in table:
            if "__terminal-host" in cmd and (self.root in cmd or re.search(rf"\b{re.escape(self.session)}\b", cmd)):
                roots.add(pid)
        # A host seen once stays this run's while it lives (pid reuse: still a terminal host).
        roots |= {pid for pid in self.hosts_seen if "__terminal-host" in commands.get(pid, "")}
        found = procstat.descendants(roots, table)
        hosts = {pid for pid in found if "__terminal-host" in commands.get(pid, "")}
        self.hosts_seen |= hosts
        out = {}
        for pid in found:
            cmd = commands.get(pid, "")
            if self.proc and pid == self.proc.pid:
                out[pid] = "tui-daemon"
            elif pid in hosts:
                out[pid] = "terminal-host"
            else:
                exe = os.path.basename(cmd.split()[0]) if cmd else "?"
                out[pid] = "workload:" + exe[:24]
        return out


def _flood_argv(fifo: str, size: int) -> list[str]:
    # `exec cat` keeps the terminal open after the flood, blocked on input (no timer).
    return ["/bin/sh", "-c", f"LC_ALL=C yes | head -c {size}; printf done > '{fifo}'; exec cat"]


def _wait_fifos(fifos: list[str], timeout: float) -> list[float | None]:
    """Blocks on each FIFO until its writer reports; returns the seconds each took."""
    t0 = time.monotonic()
    done: list[float | None] = [None] * len(fifos)

    def reader(i, path):
        with open(path, "rb") as handle:  # blocks until the shell opens it for writing
            handle.read()
        done[i] = time.monotonic() - t0

    threads = [threading.Thread(target=reader, args=(i, p), daemon=True) for i, p in enumerate(fifos)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=max(0.0, timeout - (time.monotonic() - t0)))
    return done


class Attach:
    """Counts the bytes one attach-surface client receives (what an app client reads)."""

    def __init__(self, sock: str, surface):
        self.conn = Conn(sock, timeout=600)
        self.bytes = 0
        self.conn.send_line({"id": 1, "cmd": "attach-surface", "surface": surface, "cols": 120, "rows": 40})
        self.thread = threading.Thread(target=self._drain, daemon=True)
        self.thread.start()

    def _drain(self):
        try:
            while True:
                chunk = self.conn.sock.recv(1 << 20)
                if not chunk:
                    return
                self.bytes += len(chunk)
        except OSError:
            return

    def close(self):
        self.conn.close()


def run_tui(args, build: dict, out_dir: str) -> list[str]:
    paths = []
    rng = random.Random(args.seed)
    scenarios = args.scenarios.split(",")
    for scenario in scenarios:
        root = tempfile.mkdtemp(prefix="p100t-", dir=args.root_dir)
        daemon = TuiDaemon(args.tui, root)
        run = runlib.Run(scenario, "headless-tui", args.seed, vars(args), build, args.host_class)
        run.data["tool"] = {"cmux-tui": args.tui, "version": None}
        try:
            cold_ms = daemon.start()
            run.data["tool"]["version"] = daemon.ident.get("version")
            run.metric("start.cold_identify_ms", round(cold_ms, 1))
            conn = Conn(daemon.sock)
            if scenario == "S0":
                _tui_s0(run, daemon, conn, args, rng)
            elif scenario == "S1":
                _tui_s1(run, daemon, conn, args)
            elif scenario in ("S3", "S4"):
                _tui_s3(run, daemon, conn, args, restart=scenario == "S4")
            else:
                run.note(f"{scenario}: no headless-tui part")
            conn.close()
        except (Exception, SystemExit) as error:  # noqa: BLE001 - the run records the failure and goes on
            run.data["error"] = repr(error)
            run.data["daemon_log_tail"] = _tail(os.path.join(root, "daemon.log"))
        finally:
            try:
                if daemon.proc and daemon.proc.poll() is None:
                    run.metric("stop.shutdown_end_terminals_ms", round(daemon.shutdown(True), 1))
            except Exception as error:  # noqa: BLE001
                run.data.setdefault("teardown_error", repr(error))
            daemon.reap()
            left = daemon.wait_hosts_gone(10)
            run.metric("stop.leftover_terminal_hosts", len(left))
            run.data["on_disk"] = {"state": procstat.du(daemon.state), "home": procstat.du(daemon.home)}
            run.metric("disk.state_mb", run.data["on_disk"]["state"]["allocated_mb"])
            paths.append(run.write(out_dir))
            shutil.rmtree(root, ignore_errors=True)
            print(f"perf100: {scenario} headless-tui done ({run.data.get('error') or 'ok'})", flush=True)
    return paths


def _tail(path: str) -> str:
    try:
        with open(path, errors="replace") as handle:
            return handle.read()[-3000:]
    except OSError:
        return ""


def _new_workspaces(conn: Conn, count: int) -> list[dict]:
    """`count` workspaces, each with its first terminal; returns [{workspace, surface}]."""
    made = []
    for i in range(count):
        data = must(conn.call("new-workspace", name=f"w{i}", cols=120, rows=40), "new-workspace")
        made.append({"surface": data.get("surface"), "workspace": data.get("workspace")})
    tree = must(conn.call("list-workspaces"), "list-workspaces")
    ids = [w["id"] for w in tree.get("workspaces", [])][-count:]
    for entry, ws in zip(made, ids):
        entry["workspace"] = entry["workspace"] or ws
    return made


def _tui_s0(run, daemon, conn, args, rng):
    """10 idle shells and 3 idle agent TUIs, then the idle window."""
    made = _new_workspaces(conn, 1)
    ws = made[0]["workspace"]
    for i in range(args.terminals - 1):
        must(conn.call("create-terminal", workspace=ws, argv=["/bin/sh"], cols=120, rows=40), "create-terminal")
    for i in range(args.agent_tuis):
        must(conn.call("create-terminal", workspace=ws, argv=[sys.executable, os.path.join(FIXTURES, "idle_tui.py"),
                                                              str(rng.randrange(1000))], cols=120, rows=40),
             "create-terminal")
    time.sleep(args.settle)  # bench: let one-shot startup work finish before the idle window
    window = procstat.Tracker(daemon.discover).start()
    time.sleep(args.idle)  # bench: the measured idle window
    units = args.terminals + args.agent_tuis
    entry = run.phase("idle", window.stop())
    run.data["phases"]["idle"]["per_unit"] = runlib.per_unit(entry["groups"], units, "terminal", ("cmux", "tui"))
    for key, value in run.data["phases"]["idle"]["per_unit"]["terminal"].items():
        run.metric(f"idle.per_terminal.{key}", value)


def _tui_s1(run, daemon, conn, args):
    """One terminal floods `--flood-mb`, then `--flood-terminals` at once; one attached client each."""
    size = int(args.flood_mb * 1048576)
    for phase, count in (("flood1", 1), (f"flood{args.flood_terminals}", args.flood_terminals)):
        made = _new_workspaces(conn, 1)
        ws = made[0]["workspace"]
        fifos, surfaces = [], []
        for i in range(count):
            fifo = os.path.join(daemon.root, f"{phase}-{i}.fifo")
            os.mkfifo(fifo)
            fifos.append(fifo)
        attaches = []
        window = procstat.Tracker(daemon.discover, interval=0.5).start()
        t0 = time.monotonic()
        for fifo in fifos:
            data = must(conn.call("create-terminal", workspace=ws, argv=_flood_argv(fifo, size), cols=120, rows=40),
                        "create-terminal")
            surfaces.append(data.get("surface"))
            attaches.append(Attach(daemon.sock, data.get("surface")))
        done = _wait_fifos(fifos, timeout=args.flood_timeout)
        wall = time.monotonic() - t0
        entry = run.phase(phase, window.stop())
        for a in attaches:
            a.close()
        finished = [d for d in done if d is not None]
        run.metric(f"{phase}.wall_s", round(wall, 2))
        run.metric(f"{phase}.finished", len(finished))
        if finished:
            run.metric(f"{phase}.throughput_mb_s", round(len(finished) * args.flood_mb / max(finished), 1))
        run.metric(f"{phase}.client_socket_mb", round(sum(a.bytes for a in attaches) / procstat.MB, 1))
        cpu = entry["groups"].get("cmux", {}).get("cpu_s", 0)
        run.metric(f"{phase}.cmux_cpu_s_per_100mb", round(cpu / (count * args.flood_mb / 100), 3))
        written = entry["groups"].get("cmux", {}).get("disk_written_mb", 0)
        run.metric(f"{phase}.cmux_disk_written_per_output_mb", round(written / (count * args.flood_mb), 4))
        if len(finished) < count:
            run.note(f"{phase}: {count - len(finished)} of {count} floods did not finish in {args.flood_timeout} s")


def _tui_s3(run, daemon, conn, args, restart: bool):
    """`--workspaces` workspaces with `--per-workspace` idle terminals each; then (S4) restart."""
    total = args.workspaces * args.per_workspace
    cap = _pty_cap(args)
    if cap is not None and total > cap:
        per = max(1, cap // args.workspaces)
        run.note(f"S3: {total} terminals exceed the free PTYs ({cap}); ran {args.workspaces} x {per}")
        run.unverified(f"S3 at {total} terminals: this host's PTY limit allows {cap}")
        total = args.workspaces * per
    else:
        per = args.per_workspace
    window = procstat.Tracker(daemon.discover, interval=2.0).start()
    t0 = time.monotonic()
    made = _new_workspaces(conn, args.workspaces)
    for entry in made:
        for _ in range(per - 1):
            must(conn.call("create-terminal", workspace=entry["workspace"], argv=["/bin/sh"], cols=120, rows=40),
                 "create-terminal")
    create_s = time.monotonic() - t0
    run.phase("create", window.stop())
    run.metric("create.terminals", total)
    run.metric("create.seconds", round(create_s, 2))
    run.metric("create.terminals_per_s", round(total / create_s, 1))
    time.sleep(args.settle)  # bench: let creation work drain before the idle window
    window = procstat.Tracker(daemon.discover, interval=2.0).start()
    time.sleep(args.idle)  # bench: the measured idle window
    entry = run.phase("idle", window.stop())
    units = runlib.per_unit(entry["groups"], total, "terminal", ("cmux", "tui"))
    entry["per_unit"] = units
    for key, value in units["terminal"].items():
        run.metric(f"idle.per_terminal.{key}", value)
    lat = _echo_latency(daemon, [m["surface"] for m in made], samples=args.latency_samples)
    run.latency("keystroke_to_echo_headless", lat)
    if restart:
        conn.close()
        window = procstat.Tracker(daemon.discover, interval=0.5).start()
        stop_ms = daemon.shutdown(False)  # keep the terminals: a version handoff
        start_ms = daemon.start()
        t0 = time.monotonic()
        conn2 = Conn(daemon.sock, timeout=600)
        tree = must(conn2.call("list-workspaces"), "list-workspaces")
        adopted_ms = (time.monotonic() - t0) * 1000 + start_ms
        conn2.close()
        run.phase("restart", window.stop())
        run.metric("restart.stop_keep_terminals_ms", round(stop_ms, 1))
        run.metric("restart.start_identify_ms", round(start_ms, 1))
        run.metric("restart.to_topology_ms", round(adopted_ms, 1))
        run.metric("restart.workspaces_after", len(tree.get("workspaces", [])))


def _echo_latency(daemon, surfaces: list, samples: int) -> list[float]:
    """`send` on the control socket to the echoed bytes on an attach stream (an idle shell)."""
    rng = random.Random(len(surfaces))
    chosen = rng.sample(surfaces, min(5, len(surfaces)))
    out = []
    ctl = Conn(daemon.sock)
    for surface in chosen:
        att = Conn(daemon.sock, timeout=10)
        try:
            att.send_line({"id": 1, "cmd": "attach-surface", "surface": surface, "cols": 120, "rows": 40})
            while att.read_line().get("id") != 1:
                pass
            for _ in range(max(1, samples // len(chosen))):
                marker = f"q{rng.randrange(10**8, 10**9)}"
                t0 = time.perf_counter()
                must(ctl.call("send", surface=surface, text=marker), "send")
                got = b""
                deadline = time.time() + 5
                while time.time() < deadline:
                    m = att.read_line()
                    if m.get("event") == "output" and m.get("surface") == surface:
                        got += base64.b64decode(m.get("data", ""))
                        if marker.encode() in got:
                            out.append((time.perf_counter() - t0) * 1000)
                            break
                ctl.call("send", surface=surface, text="\x15")  # Ctrl-U clears the line
        except (OSError, ConnectionError, RuntimeError, ValueError):
            continue
        finally:
            att.close()
    ctl.close()
    return out


def _pty_cap(args) -> int | None:
    """macOS: PTYs this run may take (ptmx_max minus PTYs in use minus the reserve, at most the
    budget); None elsewhere."""
    if not procstat.IS_MAC:
        return None
    try:
        ptmx = int(runlib.sh(["sysctl", "-n", "kern.tty.ptmx_max"]))
    except ValueError:
        return None
    in_use = sum(1 for name in os.listdir("/dev") if name.startswith("ttys") and name[4:].isdigit())
    return max(1, min(args.pty_budget, ptmx - in_use - args.pty_reserve))


# ---------------------------------------------------------------- acpmux


class Acpmux:
    def __init__(self, binary: str, root: str):
        self.binary = binary
        self.root = root
        for name in ("home", "xdg", "amx", "work", "agent"):
            os.makedirs(os.path.join(root, name), exist_ok=True)
        with open(os.path.join(root, "amx", "config.json"), "w") as handle:
            json.dump({"permissionPolicy": "approve-all"}, handle)
        # A private copy of the agent: its path names this run's processes.
        self.agent = os.path.join(root, "agent", "replay_agent.py")
        for name in ("replay_agent.py", "streams.py"):
            shutil.copy(os.path.join(FIXTURES, name), os.path.join(root, "agent", name))
        shutil.copytree(os.path.join(FIXTURES, "agent-streams"), os.path.join(root, "agent", "agent-streams"))
        os.chmod(self.agent, 0o755)
        self.env = {"HOME": os.path.join(root, "home"), "XDG_CONFIG_HOME": os.path.join(root, "xdg"),
                    "ACPMUX_HOME": os.path.join(root, "amx"), "ACPMUX_SOCKET": os.path.join(root, "a.sock"),
                    "ACPMUX_LOGIN_ENV": "0", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": tempfile.gettempdir() + "/", "USER": os.environ.get("USER", "")}
        self.proc = None

    def cli(self, *argv, timeout=120) -> subprocess.CompletedProcess:
        return subprocess.run([self.binary, *argv], capture_output=True, text=True, env=self.env,
                              cwd=os.path.join(self.root, "work"), stdin=subprocess.DEVNULL, timeout=timeout)

    def start(self) -> float:
        t0 = time.monotonic()
        self.log = open(os.path.join(self.root, "daemon.log"), "a")
        self.proc = subprocess.Popen([self.binary, "daemon", "run", "--ready-fd", "1", "--log", "warn"],
                                     stdout=subprocess.PIPE, stderr=self.log, env=self.env,
                                     cwd=os.path.join(self.root, "work"), stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        seen = b""
        fd = self.proc.stdout.fileno()
        deadline = t0 + 60
        while b'"ready":true' not in seen:
            left = deadline - time.monotonic()
            ready, _, _ = select.select([fd], [], [], max(0.0, left))
            if not ready:
                self.reap()
                raise RuntimeError(f"acpmux printed no ready line within 60 s: {seen[-500:]!r}")
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError(f"acpmux exited before ready: {seen[-500:]!r}")
            seen += chunk
        ms = (time.monotonic() - t0) * 1000
        # Keep draining stdout so the daemon never blocks on a full pipe.
        threading.Thread(target=lambda: [None for _ in iter(lambda: os.read(fd, 65536), b"")], daemon=True).start()
        return ms

    def reap(self):
        """Last resort for the daemon this run started: SIGKILL its own Popen."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=30)

    def shutdown(self):
        try:
            self.cli("daemon", "shutdown", "--end-agents", timeout=60)
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
        self.reap()

    def discover(self) -> dict[int, str]:
        table = procstat.process_table()
        roots = {self.proc.pid} if self.proc and self.proc.poll() is None else set()
        for pid, _ppid, cmd in table:
            if self.agent in cmd or (self.binary in cmd and self.root in cmd):
                roots.add(pid)
        found = procstat.descendants(roots, table)
        commands = {pid: cmd for pid, _ppid, cmd in table}
        out = {}
        for pid in found:
            cmd = commands.get(pid, "")
            if self.agent in cmd:
                out[pid] = "agent-standin"
            elif self.proc and pid == self.proc.pid:
                out[pid] = "acpmux-daemon"
            elif cmd.startswith(self.binary):
                rest = cmd[len(self.binary):].split()
                if rest[:1] in (["send"], ["new"], ["wait"], ["--json"], ["harness"], ["daemon"]) and \
                        rest[:2] != ["daemon", "run"]:
                    out[pid] = "acpmux-client"  # this runner's own CLI calls (group harness)
                else:
                    out[pid] = "acpmux-" + (rest[0] if rest else "child")
            else:
                out[pid] = "workload:" + os.path.basename(cmd.split()[0])[:24] if cmd else "workload:?"
        return out


def _send_stream(amx: Acpmux, sid: str, prompt: str, seen: dict, marks: list, procs: list):
    """`acpmux send` as the client of one session; timestamps each marker when its bytes arrive."""
    proc = subprocess.Popen([amx.binary, "send", sid, prompt], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=amx.env, cwd=os.path.join(amx.root, "work"), stdin=subprocess.DEVNULL)
    procs.append(proc)
    tail = b""
    total = 0
    while True:
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            break
        now = time.time()
        total += len(chunk)
        tail = (tail + chunk)[-(len(chunk) + 64):]
        start = 0
        while True:
            i = tail.find(b"[pm:", start)
            if i < 0:
                break
            j = tail.find(b"]", i)
            if j < 0:
                break
            mark = tail[i:j + 1].decode(errors="replace")
            seen.setdefault(mark, now)
            start = j + 1
        tail = tail[-64:]
    proc.wait()
    marks.append({"sid": sid, "rc": proc.returncode, "bytes": total})


def run_acpmux(args, build: dict, out_dir: str) -> list[str]:
    paths = []
    for count in [int(n) for n in args.sessions.split(",") if n]:
        root = tempfile.mkdtemp(prefix="p100a-", dir=args.root_dir)
        amx = Acpmux(args.acpmux, root)
        run = runlib.Run("S2", f"headless-acpmux-{count}", args.seed, dict(vars(args), sessions_count=count), build,
                         args.host_class)
        run.data["tool"] = {"acpmux": args.acpmux}
        rng = random.Random(args.seed + count)
        try:
            run.metric("start.ready_ms", round(amx.start(), 1))
            added = amx.cli("--json", "harness", "add", "perf100", "--command", amx.agent)
            if added.returncode != 0:
                raise RuntimeError(f"harness add: {added.stdout[-300:]} {added.stderr[-300:]}")
            window = procstat.Tracker(amx.discover, interval=1.0).start()
            sids = []
            lock = threading.Lock()

            def make(i):
                made = amx.cli("--json", "new", "-d", "-m", "perf100", f"perf100 session {i}")
                try:
                    sid = _session_id(made.stdout)
                except (ValueError, KeyError, IndexError):
                    raise RuntimeError(f"new: {made.stdout[-300:]} {made.stderr[-300:]}")
                with lock:
                    sids.append(sid)

            t0 = time.monotonic()
            _pool(make, range(count), 8)
            run.metric("create.seconds", round(time.monotonic() - t0, 2))
            run.phase("create", window.stop())
            time.sleep(args.settle)  # bench: let session start work finish before the idle window
            window = procstat.Tracker(amx.discover, interval=1.0).start()
            time.sleep(args.idle)  # bench: the measured idle window (sessions open, no turn)
            idle = run.phase("idle", window.stop())
            units = runlib.per_unit(idle["groups"], count, "session", ("cmux", "acpmux", "agents"))
            idle["per_unit"] = units
            for key, value in units["session"].items():
                run.metric(f"idle.per_session.{key}", value)
            fixtures = ["prose-8k", "mixed-24k", "code-48k"]
            seen: dict[str, float] = {}
            results: list[dict] = []
            threads = []
            clients: list = []
            window = procstat.Tracker(amx.discover, interval=1.0).start()
            t0 = time.monotonic()
            chosen = []
            for i, sid in enumerate(sids):
                fixture = fixtures[rng.randrange(len(fixtures))] if args.stream == "seeded" else args.stream
                chosen.append(fixture)
                log = os.path.join(root, f"marks-{i}.jsonl")
                prompt = f"perf100 stream={fixture} speed={args.speed} marks={args.marks} tag={i} log={log}"
                t = threading.Thread(target=_send_stream, args=(amx, sid, prompt, seen, results, clients), daemon=True)
                t.start()
                threads.append(t)
            for t in threads:
                t.join(timeout=max(0.0, args.stream_timeout - (time.monotonic() - t0)))
            wall = time.monotonic() - t0
            for proc in clients:  # this run's own clients that outlived the timeout
                if proc.poll() is None:
                    proc.kill()
            stream = run.phase("stream", window.stop())
            emitted = {}
            for i in range(len(sids)):
                try:
                    with open(os.path.join(root, f"marks-{i}.jsonl")) as handle:
                        for line in handle:
                            entry = json.loads(line)
                            emitted[entry["mark"]] = entry["t"]
                except (OSError, ValueError):
                    pass
            lat = [(seen[m] - t) * 1000 for m, t in emitted.items() if m in seen]
            run.latency("token_to_client", lat)
            run.metric("stream.wall_s", round(wall, 2))
            run.metric("stream.sessions_ok", sum(1 for r in results if r["rc"] == 0))
            client_bytes = sum(r["bytes"] for r in results)
            run.metric("stream.client_mb", round(client_bytes / procstat.MB, 2))
            manifest = _fixture_text_bytes()
            run.data["fixtures"] = manifest
            streamed = sum(manifest[f]["text_bytes"] for f in chosen)
            chunks = sum(manifest[f]["chunks"] for f in chosen)
            run.metric("stream.text_mb", round(streamed / procstat.MB, 3))
            run.metric("stream.chunks", chunks)
            sys_calls = sum((stream["groups"].get(g) or {}).get("syscalls_per_s", 0) for g in ("acpmux",)) * wall
            run.metric("stream.acpmux_syscalls_per_chunk", round(sys_calls / max(chunks, 1), 2))
            cpu = (stream["groups"].get("acpmux") or {}).get("cpu_s", 0)
            run.metric("stream.acpmux_cpu_us_per_chunk", round(cpu * 1e6 / max(chunks, 1), 1))
            cmux = stream["groups"].get("cmux", {})
            run.metric("stream.acpmux_cpu_s_per_session", round(cmux.get("cpu_s", 0) / max(count, 1), 4))
            run.metric("stream.acpmux_disk_written_mb_per_session", round(cmux.get("disk_written_mb", 0) / max(count, 1), 4))
            if len(lat) < len(emitted):
                run.note(f"token_to_client: {len(emitted) - len(lat)} of {len(emitted)} markers never reached a client")
        except Exception as error:  # noqa: BLE001
            run.data["error"] = repr(error)
            run.data["daemon_log_tail"] = _tail(os.path.join(root, "daemon.log"))
        finally:
            if amx.proc:
                amx.shutdown()
            run.data["on_disk"] = {"acpmux_home": procstat.du(os.path.join(root, "amx")),
                                   "home": procstat.du(os.path.join(root, "home"))}
            run.metric("disk.acpmux_home_mb", run.data["on_disk"]["acpmux_home"]["allocated_mb"])
            paths.append(run.write(out_dir))
            shutil.rmtree(root, ignore_errors=True)
            print(f"perf100: S2 headless-acpmux-{count} done ({run.data.get('error') or 'ok'})", flush=True)
    return paths


def _fixture_text_bytes() -> dict:
    with open(os.path.join(FIXTURES, "agent-streams", "MANIFEST.json")) as handle:
        return json.load(handle)


def _pool(fn, items, workers: int):
    items = list(items)
    errors = []
    lock = threading.Lock()
    it = iter(items)

    def worker():
        while True:
            with lock:
                item = next(it, None)
            if item is None or errors:
                return
            try:
                fn(item)
            except Exception as error:  # noqa: BLE001
                errors.append(error)

    threads = [threading.Thread(target=worker) for _ in range(min(workers, max(1, len(items))))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise errors[0]


def _session_id(stdout: str) -> str:
    """The sessionId of `acp new --json` (one JSON object, possibly pretty-printed)."""
    text = stdout.strip()
    try:
        return json.loads(text)["sessionId"]
    except (ValueError, KeyError, TypeError):
        start = text.rfind("\n{")
        return json.loads(text[start + 1:] if start >= 0 else text)["sessionId"]
