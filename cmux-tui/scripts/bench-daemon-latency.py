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
            if msg.get("id") == rid and "ok" in msg:
                return msg


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
                p = subprocess.run([self.args.bin, *argv], env=env, capture_output=True, timeout=30)
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
                p = subprocess.run([self.args.bin, *chosen], env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=30)
                vals.append((time.perf_counter() - t) * 1000)
            out[name] = {**stats(vals), "argv": " ".join(chosen)}
        vals = []
        for _ in range(n):
            t = time.perf_counter()
            subprocess.run([self.args.bin, "--version"], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
            vals.append((time.perf_counter() - t) * 1000)
        out["cli-version-no-socket"] = stats(vals)
        return out

    # -- the "agents" scenario

    def agent_argv(self, index):
        """A fake agent: the real hook helper for each turn event, and one CLI call per turn."""
        bin_q = "'" + self.args.bin.replace("'", "'\\''") + "'"
        events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PreToolUse", "PostToolUse", "Stop"]
        loop = "; ".join(
            f"printf '%s' '{{\"session_id\":\"bench-agent-{index}\",\"hook_event_name\":\"{event}\","
            f"\"tool_name\":\"Bash\",\"prompt\":\"bench turn\"}}' | {bin_q} __agent-hook claude {event} "
            f">/dev/null 2>&1; sleep {self.args.agent_sleep}"
            for event in events
        )
        cli = f"; {bin_q} workspace list >/dev/null 2>&1" if self.args.agent_cli else ""
        script = f"while :; do {loop}{cli}; done"
        return ["/bin/sh", "-c", script]

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
        for i in range(self.args.agents):
            must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=self.agent_argv(i),
                        cols=80, rows=24), "create-terminal")
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
    ap.add_argument("--resize-rounds", type=int, default=4,
                    help="resize-mirror: how many times to run its 5 bursts per case")
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
