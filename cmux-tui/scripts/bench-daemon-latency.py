#!/usr/bin/env python3
"""Request latency of one headless cmux-tui daemon (perf-10x daemon area).

Starts an isolated headless daemon (durable state on the local disk), then
measures, per scenario, the client-side round trip of control requests on
one JSON-lines connection:

- ping, identify, list-workspaces, send (terminal write), new-tab
  (each new tab is closed again outside the timed window);
- the `cmux` CLI end to end (process start -> exit) for a session ping, the
  workspace list and a terminal write, through CMUX_TUI_SOCKET;
- the same raw requests from 10 concurrent clients.

Scenarios: "small" (1 workspace, 1 terminal) and "scale" (50 workspaces,
200 terminals, 5% of them printing steadily). Output: one PERF-DAEMON line
per (scenario, metric) and a JSON file.

Scenario "agents" (not in the default list) is a loaded Mac with many
terminal agents, the shape of the 2026-10-29 report (#27698): 80 terminals,
each a fake agent that runs the real hook helper (`cmux-tui __agent-hook
claude EVENT`, one durable journal append each, as Claude Code does on every
prompt and tool call) and a `cmux` CLI call in a loop; a churn client that
creates and closes terminals; and an "app" client that sends what the cmux
app sends (put-frontend-projection window saves, list-workspaces,
session.snapshot, identify). It reports the app requests' latency, the
requests over the app's 2 s timeout, and both daemon locks by site
(`server-stats` `locks`, or `registry_lock.top_sites` on a daemon without
it). Arguments: --agents (80), --agent-sleep (0.25 s between an agent's
hooks), --load-seconds (60), --agent-cli (1; 0 runs the hooks only, the
shipped agent hooks' real load: no shipped hook calls the CLI per turn).
Scenario "agents-hooks" is "agents" with --agent-cli 0, for the fleet
script, which passes only --scenarios (perf-10x-daemon.sh
--arg=scenarios=agents-hooks).

Scenario "cli-storm" (not in the default list) is the TYPING UNDER LOAD L1 CLI storm against a
session the size of L5 HEAVY (40 workspaces, 200 terminals, 5% printing): 8 workers run the real
`cmux` CLI (one process per call, as scripts/journeys/tui-kit/rust/src/storm.rs does) in the
storm's weighted mix (workspace, pane, tab and terminal list; tab create and close, each worker
closing only its own tabs; terminal write; screen read; notify; workspace status, progress and
log) on one shared schedule at --storm-rate calls a second. It first times each CLI kind alone,
idle, at 1 workspace and at full size (the per-call cost and how it grows with the session), and
a raw socket probe sends the same list reads during the storm (daemon time without the CLI
process). It reports per kind p50/p95/max, the achieved rate, both daemon locks by site
(`server-stats` `locks`) and the topology projections (`resource_projection`: full against
scoped, read/index/diff time, changes per commit).

Scenario "resize-mirror" (not in the default list) is a terminal resized
in bursts while a byte mirror is attached, the cost cmux-ad H10 names: a
terminal with 10,000 lines of history, one connection attached to it as a
byte mirror (`attach-surface`, read as fast as it comes), and a control
connection that resizes it with `resize-surface` in bursts of 24 steps,
back to back ("burst") and one step every 8 ms ("drag", a 120 Hz divider
drag), 5 bursts each. It reports each step's request round trip
("step": for a hosted terminal `resize-surface` replies once the size
reached the terminal host, so a step mostly waits for the geometry lock
while the previous step is applied, in a hosted terminal while its reader
installs the host's replay), the
`resized` events the mirror got per burst, and the time from sending a
burst's last step to the mirror's `resized` of the final grid ("settle").
A settle miss, a stream end (`detached`, `overflow`) or a refused resize
fails the run. `--resize-rounds` (default 4, so 20 bursts per case)
repeats the 5 bursts.

Scenario "journal-step" (not in the default list; cmux-ad m11 2) is #34628's 5-8 s maintenance
stall: agents (the "agents" scenario's hook helpers, --agents of them) fill the journal with
records the maintenance tick's roster catch-up then reads, while an "app" connection sends what
the app sends (window_record-like put-frontend-projection, list-workspaces, identify) and a churn
connection creates and closes terminals. The load runs through --journal-ticks whole maintenance
ticks: a tick starts 30 s (a release build's interval) after the previous one ended, so the
window is 30 s per tick plus --journal-tick-seconds (default 10, over #34628's 5-8 s ticks) for
each tick and for the one that may be running when the window opens. A longer tick can leave the
window short of --journal-ticks whole ticks; its slow-maintenance line shows its length. A tick
under 500 ms logs no line, so an empty slow-maintenance list does not show that a tick ran.
It reports each request kind's latency (p50/p95/p99/max), the daemon's slow-maintenance lines,
and, over the requests that start no process (put-frontend-projection, list-workspaces, identify,
close-surface), "all" and the requests over 30 ms (the typing budget's daemon share is 4 ms;
30 ms is a stall a person sees). create-terminal is reported apart and kept out of "all" and
over-30ms: a create waits for its terminal host to launch, and "create-terminal-idle" (20 of the
same creates before the agents start) shows what a create costs with no load.

Scenario "head-of-line" (not in the default list; cmux-ad m11 2, data for PL-daemon's open
question on per-request dispatch) is a request queued on a connection behind a slow request of
the same connection. The daemon's reader for a connection answers `ping` and a plain `identify`
itself and queues the connection's other legacy requests for its one dispatch thread, which takes
them in order and runs each there, except a terminal create (handed to the terminal pool) and a
waiting `wait-for` or a `clear-history` (handed to a worker). Of the churn's requests,
`close-surface` runs on that thread (its commit waits for the workspace registry lock, which a
maintenance tick's steps hold); a create leaves it at once. So, with the "journal-step" agents
and window, one connection creates a terminal and, once it is made, sends `close-surface`, then
at once `list-workspaces` (queued behind the close) and `identify` (the control: answered on the
reader, it waits for no queue). A second connection sends the same `list-workspaces` and
`identify` at the same moment. Each connection keeps its requests in flight together: one reader
thread per connection matches each reply to its request by id, and each request is timed from
its send to its reply. "list-workspaces-behind-close" minus "list-workspaces-own-connection" is
the wait in the connection's queue; "identify-behind-close" should match "identify-own-connection".

"agents", "journal-step" and "head-of-line" each end their agents (a stop file that each agent
reads once a turn, then their tabs closed) before the next scenario: two scenarios' agents at
once take every connection the daemon gives terminal processes, and it then refuses the bench's
own ("refused: server.busy"). In "journal-step" and "head-of-line" a failure (a refused
connection, an error reply, no reply in 600 s) stops the scenario and fails the run after its
numbers are printed; nothing is retried.

The daemon starts as the app starts it, with `--terminal-reap-grace-seconds 30`
(--reap-grace-seconds; a negative value leaves the flag out): a closed terminal ends after the
grace, and at most 16 closed terminals wait it out with their PTY. Without the flag a close leaves
the terminal running unplaced, so a scenario that creates and closes a few hundred terminals runs
the Mac out of PTYs (511 on macOS); "journal-step" then "head-of-line" did, on two Macs. The grace
changes the default scenarios' `new-tab` numbers: the bench closes each new tab, and once more
than 16 closed tabs wait, each close makes the reaper end the longest-closed terminal at once,
while the next `new-tab` is timed. A step in the `new-tab` series at this change comes from the
bench, not from the daemon.

Usage:
  bench-daemon-latency.py --bin target/release/cmux-tui --out result.json
"""

import argparse
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


def run_child(argv, timeout=30, **kwargs):
    """`subprocess.run` for a timed child, with a blocking wait.

    `subprocess.run(timeout=...)` waits by polling waitpid with sleeps that
    double from 1 ms (it looks at about 1, 3, 7, 15 and 31 ms), so it rounds a
    child's time up to the next look: a 5 ms CLI call measured 10 ms and a
    16 ms one 29 ms. Here the wait blocks in waitpid and a timer kills a child
    that runs past `timeout`. Raises `subprocess.TimeoutExpired` as `run` does.
    """
    if kwargs.pop("capture_output", False):
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    child = subprocess.Popen(argv, **kwargs)
    expired = threading.Event()

    def kill():
        expired.set()
        child.kill()

    timer = threading.Timer(timeout, kill)
    timer.daemon = True
    timer.start()
    try:
        stdout, stderr = child.communicate()
    finally:
        timer.cancel()
    if expired.is_set():
        raise subprocess.TimeoutExpired(argv, timeout, stdout, stderr)
    return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr)


class Conn:
    def __init__(self, path, timeout=60):
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
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            msg = self.read_line()
            if msg.get("type") == "refused":
                # The daemon refuses a connection past its connection limit with one line.
                raise ConnectionError(f"refused: {msg.get('code')}: {msg.get('message')}")
            if msg.get("id") == rid and "ok" in msg:
                return msg


class Pending:
    """One request in flight on a PipelinedConn: its send time, and its reply with the time the
    reply arrived (stamped by the connection's reader thread)."""

    def __init__(self, cmd):
        self.cmd = cmd
        self.sent = None
        self.arrived = None
        self.reply = None
        self.error = None
        self.done = threading.Event()

    def wait(self, timeout=600):
        if not self.done.wait(timeout):
            raise TimeoutError(f"{self.cmd}: no reply in {timeout} s")
        if self.error is not None:
            raise ConnectionError(f"{self.cmd}: {self.error}")
        return self.reply

    def ms(self):
        """Milliseconds from the request's send to its reply."""
        return (self.arrived - self.sent) * 1000


class PipelinedConn:
    """A JSON-lines connection with several requests in flight, as the app's daemon client keeps
    them: `send` writes a request at once (a lock covers only the write), and one reader thread
    matches each reply to its request by id and stamps when it arrived. A refusal, the socket's
    end or a read error fails every request in flight and every later send."""

    def __init__(self, path, timeout=60):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        # The reader waits for the next reply as long as it takes; each request has its own timeout.
        self.sock.settimeout(None)
        self.write_lock = threading.Lock()
        self.lock = threading.Lock()
        self.next_id = 1
        self.pending = {}
        self.failure = None
        self.reader = threading.Thread(target=self._read, name="bench-pipelined-reader", daemon=True)
        self.reader.start()

    def send(self, cmd, **params):
        pending = Pending(cmd)
        with self.write_lock:
            with self.lock:
                if self.failure is not None:
                    raise ConnectionError(f"{cmd}: {self.failure}")
                rid = self.next_id
                self.next_id += 1
                self.pending[rid] = pending
            line = (json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode()
            pending.sent = time.perf_counter()
            try:
                self.sock.sendall(line)
            except OSError as e:
                with self.lock:
                    self.pending.pop(rid, None)
                raise ConnectionError(f"{cmd}: send failed: {e!r}") from e
        return pending

    def call(self, cmd, **params):
        return self.send(cmd, **params).wait()

    def _read(self):
        buf = b""
        try:
            while True:
                chunk = self.sock.recv(1 << 20)
                arrived = time.perf_counter()
                if not chunk:
                    raise ConnectionError("control socket closed")
                lines = (buf + chunk).split(b"\n")
                buf = lines.pop()
                for line in lines:
                    msg = json.loads(line)
                    if msg.get("type") == "refused":
                        # The daemon refuses a connection past its connection limit with one line.
                        raise ConnectionError(f"refused: {msg.get('code')}: {msg.get('message')}")
                    rid = msg.get("id")
                    if "ok" not in msg or not isinstance(rid, int):
                        continue  # not a reply (an event line)
                    with self.lock:
                        pending = self.pending.pop(rid, None)
                    if pending is not None:
                        pending.reply, pending.arrived = msg, arrived
                        pending.done.set()
        except Exception as e:  # noqa: BLE001
            with self.lock:
                if self.failure is None:
                    self.failure = repr(e)
                failed, self.pending = self.pending, {}
            for pending in failed.values():
                pending.error = self.failure
                pending.done.set()

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.reader.join(timeout=10)
        try:
            self.sock.close()
        except OSError:
            pass


# A release build's maintenance interval: a tick starts this long after the previous one ended
# (`JOURNAL_MAINTENANCE_INTERVAL`, cmux-tui-core/src/mux/journal_maintenance.rs).
MAINTENANCE_INTERVAL_S = 30.0


def must(resp, what):
    if not resp.get("ok"):
        raise RuntimeError(f"{what} failed: {resp.get('error')!r}")
    return resp.get("data") or {}


def stats(vals):
    if not vals:
        return {"n": 0}
    s = sorted(vals)
    pick = lambda q: s[min(len(s) - 1, int(round(q * (len(s) - 1))))]  # noqa: E731
    return {
        "n": len(s),
        "p50_ms": round(pick(0.5), 3),
        "p95_ms": round(pick(0.95), 3),
        "p99_ms": round(pick(0.99), 3),
        "max_ms": round(s[-1], 3),
        "mean_ms": round(statistics.fmean(s), 3),
    }


class Bench:
    def __init__(self, args):
        self.args = args
        self.root = tempfile.mkdtemp(prefix="pd.", dir="/private/tmp" if sys.platform == "darwin" else None)
        self.sock_path = os.path.join(self.root, "s.sock")
        self.session = f"perfd{os.getpid()}"
        self.daemon = None
        self.env = None
        self.result = {"scenarios": {}}

    def start(self):
        home = os.path.join(self.root, "home")
        os.makedirs(home, exist_ok=True)
        env = dict(os.environ)
        for k in [k for k in env if k.startswith("CMUX")]:
            del env[k]
        env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            CMUX_TUI_CONFIG=os.path.join(self.root, "config.json"),
            SHELL="/bin/sh",
        )
        self.env = env
        argv = [self.args.bin, "--headless", "--session", self.session, "--socket", self.sock_path,
                "--state", os.path.join(self.root, "state")]
        if self.args.reap_grace_seconds >= 0:
            # As the app starts its daemon (DaemonLauncher): closed terminals end after the grace.
            argv += ["--terminal-reap-grace-seconds", str(self.args.reap_grace_seconds)]
        self.daemon_log = open(os.path.join(self.root, "daemon.log"), "a")
        self.daemon = subprocess.Popen(argv, stdout=self.daemon_log, stderr=subprocess.STDOUT, env=env,
                                       start_new_session=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {self.daemon.returncode}: {self.tail()}")
            if os.path.exists(self.sock_path):
                try:
                    c = Conn(self.sock_path)
                    self.ident = must(c.call("identify"), "identify")
                    c.close()
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            raise RuntimeError("daemon socket never appeared: " + self.tail())
        self.result["daemon"] = {"version": self.ident.get("version"), "protocol": self.ident.get("protocol")}
        log("daemon up", self.daemon.pid, self.ident.get("version"))

    def tail(self):
        try:
            with open(os.path.join(self.root, "daemon.log")) as f:
                return f.read()[-3000:]
        except OSError:
            return ""

    def stop(self):
        if not self.daemon:
            return
        try:
            c = Conn(self.sock_path, timeout=300)
            ident = must(c.call("identify"), "identify")
            c.call("shutdown-daemon", pid=ident["pid"],
                   generation=ident.get("generation") or ident.get("boot_generation") or "",
                   end_terminals=True)
            c.close()
        except Exception as e:  # noqa: BLE001
            log("shutdown failed", repr(e))
        try:
            self.daemon.wait(timeout=180)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    # -- topology

    def grow(self, workspaces, terminals, busy_fraction):
        c = Conn(self.sock_path, timeout=120)
        tree = must(c.call("list-workspaces"), "list-workspaces")
        have = len(tree.get("workspaces") or [])
        for i in range(have, workspaces):
            must(c.call("new-workspace", name=f"w{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        count = sum(1 for _ in self.surfaces(tree))
        busy_every = int(1 / busy_fraction) if busy_fraction > 0 else 0
        i = 0
        while count < terminals:
            busy = busy_every and i % busy_every == 0
            argv = (["perl", "-e", '$|=1; my $n=0; while (1) { print "busy ", $n++, " ", "x" x 60, "\\n"; select(undef,undef,undef,0.05); }']
                    if busy else ["/bin/sh"])
            must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=argv, cols=80, rows=24),
                 "create-terminal")
            count += 1
            i += 1
        c.close()

    def surfaces(self, tree):
        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k in ("surface", "surface_id") and isinstance(v, (int, str)):
                        yield v
                    else:
                        yield from walk(v)
            elif isinstance(node, list):
                for v in node:
                    yield from walk(v)
        seen = set()
        for s in walk(tree):
            if s not in seen:
                seen.add(s)
                yield s

    def first_surface(self, c):
        tree = must(c.call("list-workspaces"), "list-workspaces")
        return next(iter(self.surfaces(tree)))

    # -- measurement

    def raw(self, n):
        out = {}
        c = Conn(self.sock_path)
        surface = self.first_surface(c)
        plans = {
            "ping": lambda: c.call("ping"),
            "identify": lambda: c.call("identify"),
            "list-workspaces": lambda: c.call("list-workspaces"),
            "send": lambda: c.call("send", surface=surface, text=":\r"),
        }
        for name, fn in plans.items():
            for _ in range(5):
                fn()
            vals = []
            for _ in range(n):
                t = time.perf_counter()
                r = fn()
                vals.append((time.perf_counter() - t) * 1000)
                if not r.get("ok"):
                    raise RuntimeError(f"{name}: {r.get('error')!r}")
            out[name] = stats(vals)
        vals = []
        for _ in range(max(10, n // 10)):
            t = time.perf_counter()
            d = must(c.call("new-tab", cols=80, rows=24), "new-tab")
            vals.append((time.perf_counter() - t) * 1000)
            tab_surface = d.get("surface")
            if tab_surface is not None:
                c.call("close-surface", surface=tab_surface)
        out["new-tab"] = stats(vals)
        c.close()
        return out

    def concurrent(self, clients, n):
        vals = {"ping": [], "identify": [], "list-workspaces": []}
        errors = []
        lock = threading.Lock()
        barrier = threading.Barrier(clients)

        def worker():
            try:
                c = Conn(self.sock_path)
                local = {k: [] for k in vals}
                barrier.wait()
                for _ in range(n):
                    for name in vals:
                        t = time.perf_counter()
                        r = c.call(name)
                        local[name].append((time.perf_counter() - t) * 1000)
                        if not r.get("ok"):
                            raise RuntimeError(f"{name}: {r.get('error')!r}")
                c.close()
                with lock:
                    for k in vals:
                        vals[k].extend(local[k])
            except Exception as e:  # noqa: BLE001
                errors.append(repr(e))

        ts = [threading.Thread(target=worker) for _ in range(clients)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        out = {f"c{clients}-{k}": stats(v) for k, v in vals.items()}
        if errors:
            out["errors"] = errors[:5]
        return out

    def cli(self, n):
        env = dict(self.env)
        env["CMUX_TUI_SOCKET"] = self.sock_path
        c = Conn(self.sock_path)
        surface = self.first_surface(c)
        c.close()
        cmds = {
            "cli-ping": [["session", "current", "ping"], ["ping"]],
            "cli-workspace-list": [["workspace", "list"]],
            "cli-terminal-write": [["terminal", str(surface), "write", "--text", ":\r"],
                                   ["terminal", "current", "write", "--text", ":\r"]],
        }
        out = {}
        for name, candidates in cmds.items():
            chosen = None
            for argv in candidates:
                p = run_child([self.args.bin, *argv], env=env, capture_output=True)
                if p.returncode == 0:
                    chosen = argv
                    break
                log(name, argv, "exit", p.returncode, p.stderr.decode(errors="replace")[-300:])
            if not chosen:
                out[name] = {"n": 0, "error": "no working CLI form"}
                continue
            vals = []
            for _ in range(n):
                t = time.perf_counter()
                p = run_child([self.args.bin, *chosen], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
                vals.append((time.perf_counter() - t) * 1000)
            out[name] = {**stats(vals), "argv": " ".join(chosen)}
        vals = []
        for _ in range(n):
            t = time.perf_counter()
            run_child([self.args.bin, "--version"], env=env, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL)
            vals.append((time.perf_counter() - t) * 1000)
        out["cli-version-no-socket"] = stats(vals)
        return out

    # -- the "agents" scenario

    def agent_argv(self, index, stop):
        """A fake agent: the real hook helper for each turn event, and one CLI call per turn. It ends
        after the turn in which the file `stop` (a path) appears."""
        bin_q = "'" + self.args.bin.replace("'", "'\\''") + "'"
        events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PreToolUse", "PostToolUse", "Stop"]
        loop = "; ".join(
            f"printf '%s' '{{\"session_id\":\"bench-agent-{index}\",\"hook_event_name\":\"{event}\","
            f"\"tool_name\":\"Bash\",\"prompt\":\"bench turn\"}}' | {bin_q} __agent-hook claude {event} "
            f">/dev/null 2>&1; sleep {self.args.agent_sleep}"
            for event in events
        )
        cli = f"; {bin_q} workspace list >/dev/null 2>&1" if self.args.agent_cli else ""
        stop_q = "'" + stop.replace("'", "'\\''") + "'"
        return ["/bin/sh", "-c", f"while [ ! -e {stop_q} ]; do {loop}{cli}; done"]

    def start_agents(self, c, ws_ids, stop):
        """`--agents` fake agents that end once `stop` exists; returns their surfaces."""
        surfaces = []
        for i in range(self.args.agents):
            d = must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=self.agent_argv(i, stop),
                            cols=80, rows=24), "create-terminal")
            if d.get("surface") is not None:
                surfaces.append(d["surface"])
        return surfaces

    def end_agents(self, c, surfaces, stop):
        """Ends a scenario's agents (each after its turn) and closes their surfaces, so the next
        scenario starts with none of them (two scenarios' agents at once take every connection the
        daemon gives terminal processes, and it refuses the bench's own)."""
        with open(stop, "w"):
            pass
        time.sleep(3.0)
        for surface in surfaces:
            # Not checked: the tab of an agent that already ended is gone, and its close answers
            # "unknown surface".
            c.call("close-surface", surface=surface)

    def server_stats(self, c):
        r = c.call("server-stats", include=["locks", "write_path"])
        return r.get("data") or {} if r.get("ok") else {}

    def agents(self, name="agents"):
        log("scenario", name, self.args.agents, "agents")
        c = Conn(self.sock_path, timeout=300)
        for i in range(20):
            must(c.call("new-workspace", name=f"a{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        stop_agents = os.path.join(self.root, f"stop-{name}")
        agent_surfaces = self.start_agents(c, ws_ids, stop_agents)
        time.sleep(self.args.settle)
        before = self.server_stats(c)
        stop = threading.Event()
        lat = {k: [] for k in ("put-frontend-projection", "list-workspaces", "session.snapshot", "identify",
                               "churn-create-terminal", "churn-close-surface")}
        timeouts = {k: 0 for k in lat}
        errors = []
        lock = threading.Lock()
        app_timeout_ms = 2000.0

        def record(kind, ms, ok, err=None):
            with lock:
                lat[kind].append(ms)
                if ms > app_timeout_ms:
                    timeouts[kind] += 1
                if not ok and len(errors) < 10:
                    errors.append(f"{kind}: {err!r}")

        def app():
            conn = Conn(self.sock_path, timeout=600)
            k = 0
            while not stop.is_set():
                k += 1
                plans = [
                    ("put-frontend-projection", lambda: conn.call(
                        "put-frontend-projection", frontend="cmux-next", scope="personal", subject_key="windows",
                        schema_version=1, origin="bench-app", mutation_id=f"bench-{os.getpid()}-{k}",
                        projection={"windows": [{"id": "w1", "frame": [0, 0, 1200 + k % 7, 800],
                                                 "workspace_keys": []}]})),
                    ("list-workspaces", lambda: conn.call("list-workspaces")),
                    ("session.snapshot", lambda: self.resource_call(conn, "session.snapshot")),
                    ("identify", lambda: conn.call("identify")),
                ]
                for kind, fn in plans:
                    t = time.perf_counter()
                    try:
                        r = fn()
                        record(kind, (time.perf_counter() - t) * 1000, r.get("ok"), r.get("error"))
                    except Exception as e:  # noqa: BLE001
                        record(kind, (time.perf_counter() - t) * 1000, False, e)
                stop.wait(0.05)
            conn.close()

        def churn():
            conn = Conn(self.sock_path, timeout=600)
            i = 0
            while not stop.is_set():
                i += 1
                t = time.perf_counter()
                try:
                    d = must(conn.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=["/bin/sh"],
                                       cols=80, rows=24), "create-terminal")
                    record("churn-create-terminal", (time.perf_counter() - t) * 1000, True)
                    surface = d.get("surface")
                    if surface is not None:
                        t = time.perf_counter()
                        r = conn.call("close-surface", surface=surface)
                        record("churn-close-surface", (time.perf_counter() - t) * 1000, r.get("ok"), r.get("error"))
                except Exception as e:  # noqa: BLE001
                    record("churn-create-terminal", (time.perf_counter() - t) * 1000, False, e)
                stop.wait(0.5)
            conn.close()

        threads = [threading.Thread(target=app), threading.Thread(target=churn)]
        for t in threads:
            t.start()
        stop.wait(self.args.load_seconds)
        stop.set()
        for t in threads:
            t.join()
        after = self.server_stats(c)
        self.end_agents(c, agent_surfaces, stop_agents)
        c.close()
        res = {k: stats(v) for k, v in lat.items()}
        app_all = [v for k in ("put-frontend-projection", "list-workspaces", "session.snapshot", "identify")
                   for v in lat[k]]
        res["app-all"] = stats(app_all)
        res["app_timeouts"] = timeouts
        res["errors"] = errors
        res["server_stats_before"] = before
        res["server_stats_after"] = after
        self.result["scenarios"][name] = res
        for metric, s in res.items():
            if isinstance(s, dict) and "n" in s:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')}", flush=True)
        print(f"PERF-DAEMON {name} app-timeouts-over-2s {json.dumps(timeouts, sort_keys=True)}", flush=True)
        if errors:
            print(f"PERF-DAEMON {name} errors {errors}", flush=True)
        self.print_locks(name, after)

    def resource_call(self, conn, operation):
        rid = conn.next_id
        conn.next_id += 1
        request = {"protocol": "cmux.protocol/2", "type": "request", "id": f"bench-{rid}",
                   "operation": operation, "params": {"machine": "current", "session": "current"}}
        conn.sock.sendall((json.dumps(request) + "\n").encode())
        while True:
            msg = conn.read_line()
            if msg.get("id") == f"bench-{rid}" and msg.get("type") == "response":
                return {"ok": msg.get("ok"), "error": msg.get("error")}

    @staticmethod
    def print_locks(name, st):
        locks = st.get("locks")
        if locks:
            for lock_name in ("registry", "state"):
                d = locks.get(lock_name) or {}
                w, h = d.get("wait_us") or {}, d.get("hold_us") or {}
                print(f"PERF-DAEMON-LOCK {name} {lock_name} wait_p50_us={w.get('p50')} wait_p99_us={w.get('p99')} "
                      f"wait_max_us={w.get('max')} hold_p99_us={h.get('p99')} hold_max_us={h.get('max')} "
                      f"acquisitions={h.get('count')} stalls={d.get('stalls')} sites={d.get('sites')}", flush=True)
                for order in ("by_hold_total", "by_hold_p99"):
                    for rank, site in enumerate(d.get(order) or [], 1):
                        print(f"PERF-DAEMON-SITE {name} {lock_name} {order} {rank} {site.get('site')} "
                              f"n={site.get('acquisitions')} hold_total_us={site.get('hold_total_us')} "
                              f"hold_p99_us={site.get('hold_p99_us')} hold_max_us={site.get('hold_max_us')} "
                              f"wait_p99_us={site.get('wait_p99_us')} wait_max_us={site.get('wait_max_us')}",
                              flush=True)
            return
        reg = st.get("registry_lock") or {}
        w, h = reg.get("wait_us") or {}, reg.get("hold_us") or {}
        print(f"PERF-DAEMON-LOCK {name} registry wait_p50_us={w.get('p50')} wait_p99_us={w.get('p99')} "
              f"wait_max_us={w.get('max')} hold_p99_us={h.get('p99')} hold_max_us={h.get('max')} "
              f"acquisitions={h.get('count')} stalls={reg.get('stalls')}", flush=True)
        for rank, site in enumerate(reg.get("top_sites") or [], 1):
            print(f"PERF-DAEMON-SITE {name} registry by_hold_total {rank} {site.get('site')} "
                  f"n={site.get('acquisitions')} hold_total_us={site.get('hold_total_us')} "
                  f"hold_max_us={site.get('hold_max_us')}", flush=True)

    # -- the "cli-storm" scenario (TYPING UNDER LOAD CLI-1)

    STORM_MIX = (("workspace.list", 3), ("pane.list", 2), ("tab.list", 3), ("terminal.list", 2),
                 ("tab.create", 2), ("tab.close", 2), ("terminal.write", 4), ("screen.read", 4),
                 ("notify", 1), ("status.set", 3), ("progress.set", 3), ("log.append", 3))

    def storm_cli(self, args):
        """One `cmux` CLI call on this daemon: (ms, ok, stdout)."""
        env = {"HOME": self.env["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        t = time.perf_counter()
        try:
            p = run_child([self.args.bin, "--socket", self.sock_path, "--json", *args], env=env,
                          stdin=subprocess.DEVNULL, capture_output=True)
            ok, out = p.returncode == 0, p.stdout.decode(errors="replace")
            if not ok:
                out += p.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired:
            ok, out = False, "timeout"
        return (time.perf_counter() - t) * 1000, ok, out

    def storm_target(self):
        _, ok, out = self.storm_cli(["workspace", "list"])
        ws = json.loads(out)
        ws = (ws.get("result") if isinstance(ws, dict) else ws) or ws
        workspace = ws[0]["id"]
        _, ok, out = self.storm_cli(["pane", "list", "--workspace", workspace])
        panes = json.loads(out)
        panes = (panes.get("result") if isinstance(panes, dict) else panes) or panes
        pane = panes[0]["id"]
        _, ok, out = self.storm_cli(["terminal", "list", "--pane", pane])
        terms = json.loads(out)
        terms = (terms.get("result") if isinstance(terms, dict) else terms) or terms
        return workspace, pane, terms[0]["id"]

    def storm_argv(self, kind, target, worker, n, close):
        ws, pane, term = target
        return {
            "workspace.list": ["workspace", "list"],
            "pane.list": ["pane", "list", "--workspace", ws],
            "tab.list": ["tab", "list", "--pane", pane],
            "terminal.list": ["terminal", "list", "--pane", pane],
            "tab.create": ["tab", "create", "terminal", "--workspace", ws, "--pane", pane,
                           "--name", f"storm-{worker}-{n}"],
            "tab.close": ["tab", close, "close"] if close else None,
            "terminal.write": ["terminal", term, "write", "--text", f"echo storm {worker} {n}\n"],
            "screen.read": ["terminal", term, "screen", "read"],
            "notify": ["notify", "--title", f"bench {n}", "--body", f"worker {worker}", "--workspace", ws,
                       "--desktop", "false"],
            "status.set": ["workspace", ws, "status", "set", f"storm{worker}", f"call {n}"],
            "progress.set": ["workspace", ws, "progress", "set", f"{(n % 100) / 100:.2f}", "--label", "storm"],
            "log.append": ["workspace", ws, "log", "append", f"storm {worker} call {n}", "--level", "info",
                           "--source", "bench"],
        }[kind]

    @staticmethod
    def tab_id_of(out):
        try:
            value = json.loads(out)
        except ValueError:
            return None
        stack = [value]
        while stack:
            v = stack.pop()
            if isinstance(v, dict):
                if isinstance(v.get("tab_id"), str):
                    return v["tab_id"]
                stack.extend(v.values())
            elif isinstance(v, list):
                stack.extend(v)
        return None

    def storm_idle(self, target, label, reps=15):
        """Each kind alone, back to back: the per-call cost with no contention."""
        out = {}
        for kind, _ in self.STORM_MIX:
            vals = []
            for i in range(reps):
                close = None
                if kind == "tab.close":
                    _, ok, made = self.storm_cli(self.storm_argv("tab.create", target, 99, i, None))
                    close = self.tab_id_of(made) if ok else None
                    if not close:
                        continue
                ms, ok, text = self.storm_cli(self.storm_argv(kind, target, 99, i, close))
                if not ok:
                    log(label, kind, "failed", text[-300:])
                    continue
                vals.append(ms)
                if kind == "tab.create":
                    made = self.tab_id_of(text)
                    if made:
                        self.storm_cli(["tab", made, "close"])
            out[f"{label}-{kind}"] = stats(vals)
        t = []
        for _ in range(reps):
            t0 = time.perf_counter()
            run_child([self.args.bin, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            t.append((time.perf_counter() - t0) * 1000)
        out[f"{label}-cli-version-no-socket"] = stats(t)
        return out

    def cli_storm(self, name="cli-storm"):
        log("scenario", name)
        res = {}
        c = Conn(self.sock_path, timeout=300)
        must(c.call("new-workspace", name="storm", cols=80, rows=24), "new-workspace")
        c.close()
        target = self.storm_target()
        res.update(self.storm_idle(target, "idle-1ws"))
        self.grow(40, 200, 0.05)
        time.sleep(self.args.settle)
        res.update(self.storm_idle(target, "idle-40ws"))
        c = Conn(self.sock_path, timeout=300)
        before = c.call("server-stats", include=["locks", "write_path", "resource_projection"]).get("data") or {}
        rate, workers, seconds = self.args.storm_rate, 8, self.args.load_seconds
        weights = [k for k, w in self.STORM_MIX for _ in range(w)]
        lat = {k: [] for k, _ in self.STORM_MIX}
        raw = {"raw-workspace.list": [], "raw-tab.list": []}
        failed = {k: 0 for k in lat}
        errors = []
        lock = threading.Lock()
        counter = [0]
        start = time.monotonic() + 0.5
        end = start + seconds
        stop = threading.Event()

        def worker(index):
            import random
            rng = random.Random(7 + index)
            mine = []
            while True:
                with lock:
                    n = counter[0]
                    counter[0] += 1
                due = start + n / rate
                if due >= end:
                    break
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                kind = rng.choice(weights)
                if kind == "tab.close" and not mine:
                    kind = "tab.create"
                close = mine.pop(0) if kind == "tab.close" else None
                ms, ok, text = self.storm_cli(self.storm_argv(kind, target, index, n, close))
                with lock:
                    lat[kind].append(ms)
                    if not ok:
                        failed[kind] += 1
                        if len(errors) < 10:
                            errors.append(f"{kind}: {text[-200:]}")
                if ok and kind == "tab.create":
                    made = self.tab_id_of(text)
                    if made:
                        mine.append(made)
            for tab in mine:
                self.storm_cli(["tab", tab, "close"])

        def probe():
            conn = Conn(self.sock_path, timeout=300)
            ws, pane, _ = target
            k = 0
            while not stop.is_set():
                k += 1
                for op, params in (("workspace.list", {}), ("tab.list", {"pane": pane})):
                    rid = f"probe-{k}-{op}"
                    request = {"protocol": "cmux.protocol/2", "type": "request", "id": rid, "operation": op,
                               "params": {"machine": "current", "session": "current", **params}}
                    t = time.perf_counter()
                    conn.sock.sendall((json.dumps(request) + "\n").encode())
                    while True:
                        msg = conn.read_line()
                        if msg.get("id") == rid and msg.get("type") == "response":
                            break
                    with lock:
                        raw[f"raw-{op}"].append((time.perf_counter() - t) * 1000)
                stop.wait(0.1)
            conn.close()

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(workers)]
        prober = threading.Thread(target=probe)
        prober.start()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        stop.set()
        prober.join()
        after = c.call("server-stats", include=["locks", "write_path", "resource_projection"]).get("data") or {}
        c.close()
        calls = sum(len(v) for v in lat.values())
        all_ms = [v for vals in lat.values() for v in vals]
        for kind, vals in lat.items():
            res[f"storm-{kind}"] = {**stats(vals), "failed": failed[kind]}
        res["storm-all"] = stats(all_ms)
        for k, vals in raw.items():
            res[f"storm-{k}"] = stats(vals)
        res["storm_rate"] = {"asked_per_s": rate, "ok_per_s": round(calls / seconds, 2), "calls": calls,
                             "failed": sum(failed.values())}
        res["errors"] = errors
        res["server_stats_before"] = before
        res["server_stats_after"] = after
        self.result["scenarios"][name] = res
        for metric, s in res.items():
            if isinstance(s, dict) and "n" in s:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')} mean={s.get('mean_ms')}"
                      + (f" failed={s['failed']}" if "failed" in s else ""), flush=True)
        print(f"PERF-DAEMON {name} rate {json.dumps(res['storm_rate'], sort_keys=True)}", flush=True)
        if errors:
            print(f"PERF-DAEMON {name} errors {errors}", flush=True)
        self.print_locks(name, after)
        rp = after.get("resource_projection") or {}
        rp0 = before.get("resource_projection") or {}
        delta = {k: (rp.get(k) or 0) - (rp0.get(k) or 0) for k in
                 ("projections", "full_projections", "scoped_projections", "scope_fallbacks", "commits")}
        hist = {k: {q: (rp.get(k) or {}).get(q) for q in ("p50", "p99", "max")}
                for k in ("read_us", "index_us", "diff_us", "projected_changes", "commit_us", "written_changes")}
        print(f"PERF-DAEMON-PROJECTION {name} during_storm={json.dumps(delta, sort_keys=True)} "
              f"since_start={json.dumps(hist, sort_keys=True)}", flush=True)

    def resize_mirror(self, name="resize-mirror"):
        """Resize bursts of a terminal with deep history and one byte mirror."""
        steps, bursts = 24, 5
        log("scenario", name)
        c = Conn(self.sock_path, timeout=120)
        first = must(c.call("new-workspace", name="resize-mirror", cols=120, rows=40),
                     "new-workspace").get("surface")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_id = next((w["id"] for w in tree.get("workspaces") or []
                      if first in set(self.surfaces(w))), None)
        if ws_id is None:
            raise RuntimeError(f"no workspace holds the new surface {first!r}")
        history = ('my $n=0; for (1..10000) { printf "\\e[3%dmline %05d\\e[m the quick brown fox '
                   'jumps over the lazy dog\\r\\n", $n % 8, $n; $n++ } print "history-ready\\n"; '
                   'sleep 100000')
        created = must(c.call("create-terminal", workspace=ws_id,
                              argv=["perl", "-e", history], cols=120, rows=40), "create-terminal")
        surface = created.get("surface")
        if surface is None:
            raise RuntimeError(f"create-terminal returned no surface: {created!r}")
        must(c.call("wait-for", surface=surface, pattern="history-ready", timeout_ms=60000), "wait-for")

        mirror = Conn(self.sock_path, timeout=120)
        mirror.sock.sendall((json.dumps({"id": 1, "cmd": "attach-surface", "surface": surface}) + "\n")
                            .encode())
        lock = threading.Lock()
        resized = []  # (perf_counter, cols, rows)
        attached = threading.Event()
        stop = threading.Event()
        errors = []

        def read_mirror():
            try:
                while not stop.is_set():
                    msg = mirror.read_line()
                    if msg.get("id") == 1 and "ok" in msg:
                        if not msg["ok"]:
                            raise RuntimeError(f"attach-surface failed: {msg.get('error')!r}")
                        attached.set()
                    elif msg.get("event") == "resized":
                        with lock:
                            resized.append((time.perf_counter(), msg.get("cols"), msg.get("rows")))
                    elif msg.get("event") in ("detached", "overflow"):
                        # Either ends the mirror's stream: every later number would be wrong.
                        raise RuntimeError(f"the byte mirror's stream ended: {msg!r}")
            except Exception as e:  # noqa: BLE001
                if not stop.is_set():
                    errors.append(repr(e))
                attached.set()

        reader = threading.Thread(target=read_mirror, daemon=True)
        reader.start()
        if not attached.wait(30) or errors:
            raise RuntimeError(f"byte mirror did not attach: {errors!r}")

        res = {}
        for case, interval in (("burst", 0.0), ("drag", 0.008)):
            step_ms, per_burst, settle_ms = [], [], []
            for round_index in range(self.args.resize_rounds * bursts):
                # Alternate widths so every step changes the grid.
                base = 100 + (round_index % 2) * steps
                with lock:
                    before = len(resized)
                last_sent = None
                for step in range(steps):
                    if step and interval:
                        time.sleep(max(0.0, interval - (time.perf_counter() - last_sent)))
                    last_sent = time.perf_counter()
                    reply = must(c.call("resize-surface", surface=surface, cols=base + step, rows=40),
                                 "resize-surface")
                    step_ms.append((time.perf_counter() - last_sent) * 1000)
                    if reply.get("accepted") is False:
                        raise RuntimeError(f"resize-surface was not applied: {reply!r}")
                final = (base + steps - 1, 40)
                deadline = time.perf_counter() + 10
                settled = None
                while time.perf_counter() < deadline:
                    with lock:
                        hit = next((t for t, cols, rows in resized[before:] if (cols, rows) == final), None)
                    if hit is not None:
                        settled = hit
                        break
                    time.sleep(0.001)
                # Let any replay still in flight for this burst arrive before counting.
                time.sleep(0.2)
                with lock:
                    per_burst.append(len(resized) - before)
                if settled is None:
                    errors.append(f"{case} burst {round_index}: the mirror never got {final}")
                else:
                    settle_ms.append((settled - last_sent) * 1000)
                time.sleep(0.1)  # the pause between two drags
            res[f"{case}-step"] = stats(step_ms)
            res[f"{case}-settle"] = stats(settle_ms)
            res[f"{case}-resized-per-burst"] = {
                "n": len(per_burst),
                "mean": round(statistics.fmean(per_burst), 2) if per_burst else None,
                "min": min(per_burst, default=None),
                "max": max(per_burst, default=None),
            }
        stop.set()
        mirror.close()
        c.call("close-surface", surface=surface)
        c.close()
        if errors:
            res["errors"] = errors[:5]
        self.result["scenarios"][name] = res
        failed = res.get("errors")
        for metric, s in res.items():
            if metric.endswith("resized-per-burst"):
                print(f"PERF-DAEMON {name} {metric} n={s['n']} mean={s['mean']} min={s['min']} "
                      f"max={s['max']}", flush=True)
            elif metric == "errors":
                print(f"PERF-DAEMON {name} errors {s}", flush=True)
            else:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')}", flush=True)
        if failed:
            # The numbers above are printed for diagnosis; the run fails.
            raise RuntimeError(f"{name}: {failed}")

    # -- the "journal-step" and "head-of-line" scenarios (cmux-ad m11 2)

    def journal_window(self):
        """Seconds of load that hold --journal-ticks whole maintenance ticks. A tick starts
        MAINTENANCE_INTERVAL_S after the previous one ended, so k ticks of at most d seconds end
        within k intervals and k + 1 tick lengths of any moment (the k ticks, and the one that may
        be running at that moment)."""
        k, d = self.args.journal_ticks, self.args.journal_tick_seconds
        return MAINTENANCE_INTERVAL_S * k + (k + 1) * d

    def slow_maintenance(self, log_start):
        """The daemon's slow-maintenance lines since `log_start` (a daemon.log offset)."""
        with open(os.path.join(self.root, "daemon.log"), errors="replace") as f:
            f.seek(log_start)
            return [line.strip() for line in f if "slow journal maintenance" in line]

    @staticmethod
    def created_surface(created):
        """The tab of a create-terminal reply's placed terminal; a reply without one fails the run."""
        surface = created.get("surface")
        if surface is None:
            raise RuntimeError(f"create-terminal placed no tab: {created!r}")
        return surface

    @staticmethod
    def print_scenario(name, res):
        for metric, s in res.items():
            if isinstance(s, dict) and "n" in s:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')}", flush=True)

    def journal_step(self, name="journal-step"):
        window = self.journal_window()
        log("scenario", name, self.args.agents, "agents", self.args.journal_ticks, "ticks", window, "s")
        c = Conn(self.sock_path, timeout=300)
        for i in range(10):
            must(c.call("new-workspace", name=f"j{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        # The churn's create before the agents start: what a create costs with no load.
        idle = []
        for i in range(20):
            t = time.perf_counter()
            d = must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=["/bin/sh"],
                            cols=80, rows=24), "create-terminal")
            idle.append((time.perf_counter() - t) * 1000)
            must(c.call("close-surface", surface=self.created_surface(d)), "close-surface")
        stop_agents = os.path.join(self.root, f"stop-{name}")
        agents = self.start_agents(c, ws_ids, stop_agents)
        log_start = os.path.getsize(os.path.join(self.root, "daemon.log"))
        stop = threading.Event()
        # The requests that start no process: "all" and over-30ms cover these. create-terminal
        # waits for its terminal host's launch and is reported apart.
        quick = ("put-frontend-projection", "list-workspaces", "identify", "close-surface")
        lat = {k: [] for k in quick + ("create-terminal",)}
        errors = []
        lock = threading.Lock()

        def record(kind, ms):
            with lock:
                lat[kind].append(ms)

        def failing(fn):
            # A worker that fails (its connection refused, an error reply) stops the scenario and
            # fails the run; nothing is retried.
            def run():
                try:
                    fn()
                except Exception as e:  # noqa: BLE001
                    with lock:
                        errors.append(f"{fn.__name__}: {e!r}")
                    stop.set()
            run.__name__ = fn.__name__
            return run

        def app():
            conn = Conn(self.sock_path, timeout=600)
            try:
                k = 0
                while not stop.is_set():
                    k += 1
                    for kind, fn in (
                        ("put-frontend-projection", lambda: conn.call(
                            "put-frontend-projection", frontend="cmux-next", scope="personal",
                            subject_key="windows", schema_version=1, origin="bench-app",
                            mutation_id=f"jstep-{os.getpid()}-{k}",
                            projection={"windows": [{"id": "w1", "frame": [0, 0, 1200 + k % 7, 800],
                                                     "workspace_keys": []}]})),
                        ("list-workspaces", lambda: conn.call("list-workspaces")),
                        ("identify", lambda: conn.call("identify")),
                    ):
                        t = time.perf_counter()
                        must(fn(), kind)
                        record(kind, (time.perf_counter() - t) * 1000)
                    stop.wait(0.02)
            finally:
                conn.close()

        def churn():
            conn = Conn(self.sock_path, timeout=600)
            try:
                i = 0
                while not stop.is_set():
                    i += 1
                    t = time.perf_counter()
                    d = must(conn.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=["/bin/sh"],
                                       cols=80, rows=24), "create-terminal")
                    record("create-terminal", (time.perf_counter() - t) * 1000)
                    surface = self.created_surface(d)
                    t = time.perf_counter()
                    must(conn.call("close-surface", surface=surface), "close-surface")
                    record("close-surface", (time.perf_counter() - t) * 1000)
                    stop.wait(0.2)
            finally:
                conn.close()

        threads = [threading.Thread(target=failing(f)) for f in (app, churn)]
        for t in threads:
            t.start()
        stop.wait(window)
        stop.set()
        for t in threads:
            t.join()
        try:
            self.end_agents(c, agents, stop_agents)
        except Exception as e:  # noqa: BLE001
            errors.append(f"end_agents: {e!r}")
        c.close()
        slow = self.slow_maintenance(log_start)
        res = {k: stats(v) for k, v in lat.items()}
        res["create-terminal-idle"] = stats(idle)
        res["all"] = stats([v for k in quick for v in lat[k]])
        over = {k: sum(1 for v in lat[k] if v > 30.0) for k in quick}
        res["over_30ms"] = over
        res["window_s"] = window
        res["slow_maintenance"] = slow[:20]
        res["errors"] = errors
        self.result["scenarios"][name] = res
        self.print_scenario(name, res)
        print(f"PERF-DAEMON {name} over-30ms {json.dumps(over, sort_keys=True)}", flush=True)
        for line in slow[:20]:
            print(f"PERF-DAEMON {name} slow-maintenance {line}", flush=True)
        if errors:
            print(f"PERF-DAEMON {name} errors {errors}", flush=True)
            # The numbers above are printed for diagnosis; the run fails.
            raise RuntimeError(f"{name}: {errors}")

    def head_of_line(self, name="head-of-line"):
        """A request queued behind a slow request of its connection, against the same request on a
        connection of its own, with `journal-step`'s agents and window (see the module docstring).
        One connection creates a terminal; once it is made, the connection sends `close-surface`
        (run on the connection's dispatch thread), then at once `list-workspaces` (queued behind
        it) and `identify` (answered on the daemon's reader, the control). A second connection
        sends the same two at the same moment."""
        window = self.journal_window()
        log("scenario", name, self.args.agents, "agents", self.args.journal_ticks, "ticks", window, "s")
        c = Conn(self.sock_path, timeout=300)
        for i in range(10):
            must(c.call("new-workspace", name=f"h{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        stop_agents = os.path.join(self.root, f"stop-{name}")
        agents = self.start_agents(c, ws_ids, stop_agents)
        log_start = os.path.getsize(os.path.join(self.root, "daemon.log"))
        kinds = ("create-terminal", "close-surface", "list-workspaces-behind-close", "list-workspaces-own-connection",
                 "identify-behind-close", "identify-own-connection")
        lat = {k: [] for k in kinds}
        errors = []

        def settle(batch):
            # Each request's reply, checked; each request timed from its send to its reply.
            data = {}
            for kind, pending in batch:
                data[kind] = must(pending.wait(), kind)
                lat[kind].append(pending.ms())
            return data

        shared = own = None
        try:
            shared = PipelinedConn(self.sock_path)
            own = PipelinedConn(self.sock_path)
            for conn in (shared, own):
                # Starts each connection's dispatch thread before the timed requests.
                must(conn.call("list-workspaces"), "list-workspaces")
            deadline = time.monotonic() + window
            i = 0
            while time.monotonic() < deadline:
                i += 1
                created = settle([("create-terminal", shared.send(
                    "create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=["/bin/sh"], cols=80, rows=24))])
                surface = self.created_surface(created["create-terminal"])
                settle([
                    ("close-surface", shared.send("close-surface", surface=surface)),
                    ("list-workspaces-behind-close", shared.send("list-workspaces")),
                    ("identify-behind-close", shared.send("identify")),
                    ("list-workspaces-own-connection", own.send("list-workspaces")),
                    ("identify-own-connection", own.send("identify")),
                ])
                time.sleep(0.05)
        except Exception as e:  # noqa: BLE001
            # The first failure stops the scenario and fails the run; nothing is retried.
            errors.append(repr(e))
        finally:
            for conn in (shared, own):
                if conn is not None:
                    conn.close()
        try:
            self.end_agents(c, agents, stop_agents)
        except Exception as e:  # noqa: BLE001
            errors.append(f"end_agents: {e!r}")
        c.close()
        slow = self.slow_maintenance(log_start)
        res = {k: stats(v) for k, v in lat.items()}
        res["window_s"] = window
        res["slow_maintenance"] = slow[:20]
        res["errors"] = errors
        self.result["scenarios"][name] = res
        self.print_scenario(name, res)
        for line in slow[:20]:
            print(f"PERF-DAEMON {name} slow-maintenance {line}", flush=True)
        if errors:
            print(f"PERF-DAEMON {name} errors {errors}", flush=True)
            raise RuntimeError(f"{name}: {errors}")

    def scenario(self, name, workspaces, terminals, busy):
        log("scenario", name, workspaces, terminals)
        self.grow(workspaces, terminals, busy)
        time.sleep(self.args.settle)
        res = {}
        res.update(self.raw(self.args.n))
        res.update(self.concurrent(10, max(20, self.args.n // 5)))
        res.update(self.cli(self.args.cli_n))
        self.result["scenarios"][name] = res
        for metric, s in res.items():
            if isinstance(s, dict) and "n" in s:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')}" + (f" argv=\"{s['argv']}\"" if "argv" in s else ""),
                      flush=True)
            elif metric == "errors":
                print(f"PERF-DAEMON {name} errors {s}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--cli-n", type=int, default=40)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--scenarios", default="small,scale")
    ap.add_argument("--agents", type=int, default=80)
    ap.add_argument("--agent-sleep", type=lambda v: str(float(v)), default="0.25")
    ap.add_argument("--load-seconds", type=float, default=60.0)
    ap.add_argument("--agent-cli", type=int, choices=(0, 1), default=1,
                    help="1: each fake agent also runs `cmux workspace list` once per turn; 0: hooks only")
    ap.add_argument("--storm-rate", type=float, default=120.0,
                    help="cli-storm: calls a second asked of the 8 CLI workers in total")
    ap.add_argument("--resize-rounds", type=int, default=4,
                    help="resize-mirror: how many times to run its 5 bursts per case")
    ap.add_argument("--journal-ticks", type=int, default=3,
                    help="journal-step, head-of-line: whole maintenance ticks the load runs through (a tick "
                         "starts 30 s after the previous one ended)")
    ap.add_argument("--journal-tick-seconds", type=float, default=10.0,
                    help="journal-step, head-of-line: the longest maintenance tick the window allows for, for "
                         "each tick and for the one running when the window opens")
    ap.add_argument("--reap-grace-seconds", type=int, default=30,
                    help="the daemon's --terminal-reap-grace-seconds, as the app passes it; negative: leave it out")
    args = ap.parse_args()
    b = Bench(args)
    status = 0
    try:
        b.start()
        wanted = args.scenarios.split(",")
        if "small" in wanted:
            b.scenario("small", 1, 1, 0)
        if "scale" in wanted:
            b.scenario("scale", 50, 200, 0.05)
        if "agents" in wanted:
            b.agents()
        if "resize-mirror" in wanted:
            b.resize_mirror()
        if "cli-storm" in wanted:
            b.cli_storm()
        if "journal-step" in wanted:
            b.journal_step()
        if "head-of-line" in wanted:
            b.head_of_line()
        if "agents-hooks" in wanted:
            # The hooks only: no shipped agent hook calls the CLI per turn.
            args.agent_cli = 0
            b.agents("agents-hooks")
    except Exception as e:  # noqa: BLE001
        log("FAILED", repr(e), b.tail()[-1500:])
        b.result["error"] = repr(e)
        status = 1
    finally:
        b.stop()
        with open(args.out, "w") as f:
            json.dump(b.result, f, indent=1)
    return status


if __name__ == "__main__":
    sys.exit(main())
