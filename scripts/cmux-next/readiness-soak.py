#!/usr/bin/env python3
"""cmux-next readiness soak (hq#1870 gate: "a 24h soak with 10 agents: CPU, memory, no crash").

Runs a cmux-next app copy for --hours with --agents agent sessions, --terminals terminals that
keep printing and --browsers Chromium tabs, and samples every --sample seconds:

  - CPU share, memory footprint and wakeups/s per process kind (app, cmux-tui daemon, terminal
    hosts, acpmux, agents, Chromium helpers or WebKit processes), from proc_pid_rusage
    (bench_idle.usage). Browser tabs are Chromium when the build has it, else WebKit; WebKit's
    processes are launchd's children, so every one that started after the app is counted (run
    the soak on a host where nothing else uses WebKit);
  - control-socket round trips (system.ping, snapshot.get): a reply slower than --hang-after
    seconds is a hang;
  - crashes: a new DiagnosticReports .ips of cmux, cmux-tui or acpmux, or the app, daemon or
    acpmux PID changing;
  - agent turns: every agent gets a streaming turn ("slow") every --turn-every seconds; a turn
    still running after 5 minutes is stuck.

The agents are acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py): no account, no
network, no credential on the host. The app runs with its own ACPMUX_HOME and config in a scratch
folder; the soak never touches the host's ~/.acpmux or settings.

At the end it writes report.json and report.md to --out and exits 1 when a criterion failed:
no crash, no hang, no stuck turn, memory growth (median of the last hour against the first
hour after --warmup) within --max-growth-percent and --max-growth-mb per kind, and the mean
CPU of the app and the daemon under --max-app-cpu and --max-daemon-cpu. Teardown goes through
the app's quit path, then TagTeardown (acpmux and cmux-tui shutdown, exact PIDs of this copy).

Host rules: an Aqua GUI session for this user; nothing else answering on the app's control
socket. Use a copy of the app (the nightly runner unpacks cmux-next-dev into the scratch folder).

  scripts/cmux-next/readiness-soak.py --app PATH [--hours 24] [--agents 10] [--terminals 10]
      [--browsers 4] [--sample 60] [--turn-every 300] [--out DIR]
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import plistlib
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_idle import Client, process_table, usage  # noqa: E402
from daemon_teardown import daemon_status, request, terminal_hosts  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

FAKE_AGENT = os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py")
FAKE_HARNESS = "readiness-soak-agent"
CRASH_NAMES = ("cmux", "acpmux")
STUCK_TURN_S = 300
TERMINAL_WORK = "i=0; while :; do i=$((i+1)); echo \"soak $i $(date +%T)\"; ls -l /usr/bin | head -30; sleep 2; done"
STATIC_PAGE = "<!doctype html><title>soak static</title><h1>static</h1><p>no script</p>"
TICKING_PAGE = ("<!doctype html><title>soak ticking</title><h1 id=t>0</h1>"
                "<script>let n=0;setInterval(()=>{document.getElementById('t').textContent=++n},5000)</script>")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def say(line):
    print(f"{now_iso()} {line}", flush=True)


def run(*argv, timeout=60, env=None):
    return subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout, env=env)


def bundle_tag(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, executable = info.get("CFBundleIdentifier", ""), info.get("CFBundleExecutable", "")
    prefix = "com.cmuxterm.app.debug."
    if not bundle_id.startswith(prefix):
        raise SystemExit(f"readiness-soak: {app} is {bundle_id!r}, not a tagged build ({prefix}<tag>)")
    return bundle_id[len(prefix):], executable


def acpmux_socket(home):
    """acpmux's socket for ACPMUX_HOME (config.rs socket_path): a long home falls back to
    /tmp/acpmux-<uid>/<fnv1a(home)>.sock."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred) < 96:
        return preferred
    value = 0xcbf29ce484222325
    for byte in home.encode():
        value = ((value ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{value:016x}.sock"


class Acpmux:
    """JSON-RPC over the app's acpmux socket, one request per connection."""

    def __init__(self, path):
        self.path = path

    def call(self, method, params=None, timeout=10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            try:
                sock.connect(self.path)
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1, "clientInfo": {"name": "readiness-soak", "version": "1"}}}
                req = {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}}
                sock.sendall((json.dumps(init) + "\n" + json.dumps(req) + "\n").encode())
                buffer = b""
                while True:
                    chunk = sock.recv(1 << 16)
                    if not chunk:
                        return None
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line or b"{}")
                        if message.get("id") == 2:
                            return {"error": message["error"]} if "error" in message else message.get("result")
            except (OSError, ValueError) as error:
                return {"error": str(error)}

    def sessions(self):
        reply = self.call("_acpmux/sessions") or {}
        return {s.get("sessionId"): s.get("status") for s in reply.get("sessions", [])} if "error" not in reply else {}


def wait(condition, seconds, step=1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(step)  # soak script: waiting for setup to take effect
    return None


class Soak:
    def __init__(self, args):
        self.args = args
        self.app = os.path.realpath(args.app)
        self.tag, executable = bundle_tag(self.app)
        self.binary = os.path.join(self.app, "Contents/MacOS", executable)
        self.tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        self.socket = args.socket or f"/tmp/cmux-debug-{self.tag}.sock"
        self.out = args.out
        os.makedirs(self.out, exist_ok=True)
        self.work = tempfile.mkdtemp(prefix="cmux-soak-")
        self.acpmux_home = os.path.join(self.work, "acpmux")
        self.acp = Acpmux(acpmux_socket(self.acpmux_home))
        self.samples = open(os.path.join(self.out, "samples.jsonl"), "a")
        self.events = []
        self.setup = {}
        self.agents = {}  # session id -> {"started": monotonic or None, "turns": n, "done": n}
        self.started = time.time()
        self.pids = {}
        self.webkit_before = set()

    def event(self, kind, detail):
        self.events.append({"at": now_iso(), "kind": kind, "detail": detail})
        say(f"EVENT {kind}: {detail}")

    # ---- setup ---------------------------------------------------------------------------

    def preflight(self):
        if run("launchctl", "print", f"gui/{os.getuid()}").returncode != 0:
            raise SystemExit("readiness-soak: no Aqua GUI session for this user")
        if os.path.exists(self.socket):
            try:
                Client(self.socket, timeout=3).call("system.ping")
                raise SystemExit(f"readiness-soak: something already answers on {self.socket}")
            except OSError:
                pass
        table = process_table()
        if any(cmd.startswith(self.binary) for _, _, cmd in table):
            raise SystemExit(f"readiness-soak: {self.binary} is already running")
        self.webkit_before = {pid for pid, _, cmd in table if "com.apple.WebKit." in cmd}

    def launch(self):
        os.makedirs(self.acpmux_home)
        agent = os.path.join(self.work, "fake_agent.py")
        shutil.copy(FAKE_AGENT, agent)
        with open(os.path.join(self.acpmux_home, "config.json"), "w") as handle:
            json.dump({"harnesses": {FAKE_HARNESS: {"argv": [sys.executable, agent]}}}, handle)
        self.config = os.path.join(self.work, "cmux.json")
        with open(self.config, "w") as handle:
            json.dump({"app": {"quitBehavior": "keep"}}, handle)
        env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": self.config,
               "ACPMUX_HOME": self.acpmux_home}
        log = os.path.join(self.out, "app.log")
        argv = ["open", "-n", "-g", "--stdout", log, "--stderr", log]
        for key, value in env.items():
            argv += ["--env", f"{key}={value}"]
        # LaunchServices starts the app in the Aqua session even from SSH.
        opened = run(*argv, self.app)
        if opened.returncode != 0:
            raise SystemExit(f"readiness-soak: open failed: {opened.stderr}")
        self.control = wait(lambda: self.connect(), 120, 1)
        if not self.control:
            raise SystemExit(f"readiness-soak: no control socket at {self.socket}")
        identity = self.control.call("system.identify").get("result", {})
        self.setup["identity"] = {k: identity.get(k) for k in ("pid", "build", "version", "bundle_identifier") if k in identity}
        say(f"app up: {self.setup['identity']}")

    def connect(self):
        try:
            client = Client(self.socket, timeout=10)
            return client if "error" not in client.call("system.ping") else None
        except OSError:
            return None

    def start_terminals(self):
        status = wait(lambda: daemon_status(self.tui, self.tag), 60, 2)
        if not status:
            self.setup["terminals"] = "no running daemon"
            return
        made = 0
        for index in range(self.args.terminals):
            reply = request(status["socket"], {"id": 10 + index, "cmd": "run", "argv": ["/bin/sh", "-c", TERMINAL_WORK],
                                               "new_workspace": True, "name": f"soak-terminal-{index + 1}"}, 30)
            made += bool(reply.get("ok"))
            if not reply.get("ok"):
                self.setup.setdefault("terminal_errors", []).append(str(reply.get("error"))[:200])
        self.setup["terminals"] = made

    def start_browsers(self):
        made = 0
        for index in range(self.args.browsers):
            page = os.path.join(self.work, f"page-{index}.html")
            with open(page, "w") as handle:
                handle.write(TICKING_PAGE if index % 2 else STATIC_PAGE)
            engine = self.setup.get("browser_engine", "chromium")
            reply = self.control.action(f"openBrowser.{engine}", timeout=90, url="file://" + page)
            if engine == "chromium" and (reply.get("error") or {}).get("code") == "unavailable":
                # A build without CEF (cmux NEXT DEV): WebKit tabs.
                self.setup["browser_engine"] = engine = "webkit"
                reply = self.control.action("openBrowser.webkit", timeout=90, url="file://" + page)
            self.setup.setdefault("browser_engine", engine)
            timed_out = (reply.get("error") or {}).get("code") == "timeout"
            made += timed_out or "error" not in reply
            if "error" in reply and not timed_out:
                self.setup.setdefault("browser_errors", []).append(str(reply.get("error"))[:200])
        self.setup["browsers"] = made

    def start_agents(self):
        if not wait(lambda: "error" not in (self.acp.call("_acpmux/status", timeout=3) or {"error": 1}), 120, 2):
            self.setup["agents"] = "acpmux did not answer"
            return
        self.acp.call("_acpmux/reload_config")
        for index in range(self.args.agents):
            cwd = os.path.join(self.work, f"agent-{index + 1}")
            os.makedirs(cwd)
            self.acp.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
            created = self.acp.call("session/new", {"cwd": cwd, "mcpServers": [],
                                                    "_meta": {"acpmux": {"harness": FAKE_HARNESS}}}) or {}
            if created.get("sessionId"):
                self.agents[created["sessionId"]] = {"started": None, "turns": 0, "done": 0, "cwd": cwd}
            else:
                self.setup.setdefault("agent_errors", []).append(str(created)[:200])
        self.setup["agents"] = len(self.agents)

    def prompt(self, session):
        entry = self.agents[session]
        entry["started"], entry["turns"] = time.monotonic(), entry["turns"] + 1

        def hold():
            self.acp.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "slow"}]},
                          timeout=STUCK_TURN_S + 60)
        threading.Thread(target=hold, daemon=True).start()

    # ---- sampling ------------------------------------------------------------------------

    def kinds(self):
        """{pid: kind} for every process of this app copy and its agents."""
        app_pid = self.setup["identity"].get("pid")
        found = {}
        bin_dir = os.path.join(self.app, "Contents/Resources/bin/")
        for pid, ppid, cmd in process_table():
            if pid == app_pid:
                found[pid] = "app"
            elif ppid == app_pid and " Helper" in cmd:
                found[pid] = "chromium-helper"
            elif cmd.startswith(self.tui):
                found[pid] = "terminal-host" if "__terminal-host" in cmd else "daemon"
            elif cmd.startswith(bin_dir + "acpmux"):
                found[pid] = "acpmux"
            elif self.work in cmd and "fake_agent.py" in cmd:
                found[pid] = "agent"
            elif "com.apple.WebKit." in cmd and pid not in self.webkit_before:
                found[pid] = "webkit"
        # A host's command line names neither the tag nor the bundle: the daemon's children and
        # the host records in the tag's state folder find them.
        for daemon in [pid for pid, kind in found.items() if kind == "daemon"]:
            for host in terminal_hosts(daemon, self.tag):
                found[host] = "terminal-host"
        return found

    def round_trip(self, method):
        started = time.monotonic()
        try:
            reply = Client(self.socket, timeout=self.args.hang_after).call(method)
            ok = "error" not in reply
        except (OSError, ValueError):
            ok = False
        return round((time.monotonic() - started) * 1000, 1), ok

    def crash_reports(self):
        found = []
        for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips")):
            name = os.path.basename(path).lower()
            if any(n in name for n in CRASH_NAMES) and os.path.getmtime(path) >= self.started:
                found.append(path)
        return sorted(found)

    def sample(self, before, kinds, wall):
        rows = {}
        for pid, kind in kinds.items():
            first, last = before.get(pid), usage(pid)
            if first is None or last is None:
                continue
            row = rows.setdefault(kind, {"count": 0, "cpu_percent": 0.0, "footprint_mb": 0.0, "wakeups_per_s": 0.0})
            row["count"] += 1
            row["cpu_percent"] += 100.0 * (last[0] - first[0]) / (wall * 1e9)
            row["wakeups_per_s"] += (last[1] - first[1]) / wall
            row["footprint_mb"] += last[2] / 1048576
        return {kind: {k: round(v, 2) if isinstance(v, float) else v for k, v in row.items()} for kind, row in rows.items()}

    def loop(self):
        end = time.monotonic() + self.args.hours * 3600
        next_turn = {session: time.monotonic() + i * self.args.turn_every / max(len(self.agents), 1)
                     for i, session in enumerate(self.agents)}
        seen_reports = set(self.crash_reports())
        kinds = self.kinds()
        before = {pid: usage(pid) for pid in kinds}
        for key in ("app", "daemon", "acpmux"):
            self.pids[key] = sorted(pid for pid, kind in kinds.items() if kind == key)
        tick = time.monotonic()
        while time.monotonic() < end:
            time.sleep(self.args.sample)  # soak script: the sampling interval
            wall = time.monotonic() - tick
            tick = time.monotonic()
            processes = self.sample(before, kinds, wall)
            kinds = self.kinds()
            before = {pid: usage(pid) for pid in kinds}
            for key in ("app", "daemon", "acpmux"):
                pids = sorted(pid for pid, kind in kinds.items() if kind == key)
                if pids != self.pids[key]:
                    self.event("crash" if not pids or key == "app" else "restart", f"{key} pids {self.pids[key]} -> {pids}")
                    self.pids[key] = pids
            reports = set(self.crash_reports())
            for path in sorted(reports - seen_reports):
                self.event("crash", f"crash report {os.path.basename(path)}")
            seen_reports = reports
            ping_ms, ping_ok = self.round_trip("system.ping")
            snapshot_ms, snapshot_ok = self.round_trip("snapshot.get")
            if not (ping_ok and snapshot_ok) or max(ping_ms, snapshot_ms) >= self.args.hang_after * 1000:
                self.event("hang", f"control round trip ping {ping_ms} ms ({ping_ok}), snapshot {snapshot_ms} ms ({snapshot_ok})")
            statuses = self.acp.sessions()
            for session, entry in self.agents.items():
                running = statuses.get(session) == "running"
                if entry["started"] is not None and not running:
                    entry["started"], entry["done"] = None, entry["done"] + 1
                if entry["started"] is not None and time.monotonic() - entry["started"] > STUCK_TURN_S:
                    self.event("stuck-turn", f"agent {session} turn {entry['turns']} running for over {STUCK_TURN_S} s")
                    entry["started"] = None
                if entry["started"] is None and time.monotonic() >= next_turn[session]:
                    self.prompt(session)
                    next_turn[session] = time.monotonic() + self.args.turn_every
            record = {"at": now_iso(), "elapsed_s": round(time.time() - self.started), "processes": processes,
                      "ping_ms": ping_ms, "snapshot_ms": snapshot_ms,
                      "turns": sum(e["turns"] for e in self.agents.values()),
                      "turns_done": sum(e["done"] for e in self.agents.values())}
            self.samples.write(json.dumps(record) + "\n")
            self.samples.flush()

    # ---- report --------------------------------------------------------------------------

    def report(self):
        self.samples.close()
        with open(os.path.join(self.out, "samples.jsonl")) as handle:
            samples = [json.loads(line) for line in handle if line.strip()]
        warm = [s for s in samples if s["elapsed_s"] >= self.args.warmup]
        hour = 3600
        first = [s for s in warm if s["elapsed_s"] < self.args.warmup + hour]
        last_start = (warm[-1]["elapsed_s"] - hour) if warm else 0
        last = [s for s in warm if s["elapsed_s"] >= last_start]
        kinds = sorted({k for s in samples for k in s["processes"]})
        summary, failures = {}, []

        def median(rows, kind, key):
            values = [s["processes"][kind][key] for s in rows if kind in s["processes"]]
            return round(statistics.median(values), 2) if values else None

        for kind in kinds:
            cpu = [s["processes"][kind]["cpu_percent"] for s in warm if kind in s["processes"]]
            summary[kind] = {
                "mean_cpu_percent": round(statistics.fmean(cpu), 2) if cpu else None,
                "max_cpu_percent": round(max(cpu), 2) if cpu else None,
                "footprint_mb_first_hour": median(first, kind, "footprint_mb"),
                "footprint_mb_last_hour": median(last, kind, "footprint_mb"),
                "wakeups_per_s_median": median(warm, kind, "wakeups_per_s"),
            }
            row = summary[kind]
            start_mb, end_mb = row["footprint_mb_first_hour"], row["footprint_mb_last_hour"]
            if start_mb and end_mb and kind in ("app", "daemon", "acpmux"):
                growth = end_mb - start_mb
                row["growth_mb"], row["growth_percent"] = round(growth, 1), round(100 * growth / start_mb, 1)
                if growth > self.args.max_growth_mb and row["growth_percent"] > self.args.max_growth_percent:
                    failures.append(f"{kind} memory grew {growth:.0f} MB ({row['growth_percent']}%) from the first to the last hour")
        for kind, limit in (("app", self.args.max_app_cpu), ("daemon", self.args.max_daemon_cpu)):
            mean = (summary.get(kind) or {}).get("mean_cpu_percent")
            if mean is not None and mean > limit:
                failures.append(f"{kind} mean CPU {mean}% over {limit}%")
        for kind in ("crash", "hang", "stuck-turn"):
            count = sum(1 for e in self.events if e["kind"] == kind)
            if count:
                failures.append(f"{count} {kind} event(s)")
        for name in ("terminals", "browsers", "agents"):
            wanted, got = getattr(self.args, name), self.setup.get(name)
            if got != wanted:
                failures.append(f"setup: {got} of {wanted} {name}")
        hours = round((samples[-1]["elapsed_s"] if samples else 0) / 3600, 2)
        if hours < self.args.hours * 0.95:
            failures.append(f"ran {hours} h of {self.args.hours} h")
        pings = sorted(s["snapshot_ms"] for s in samples)
        result = {"ok": not failures, "failures": failures, "hours": hours, "setup": self.setup,
                  "app": self.app, "summary": summary, "events": self.events,
                  "snapshot_ms_p50": pings[len(pings) // 2] if pings else None,
                  "snapshot_ms_p99": pings[int(len(pings) * 0.99)] if pings else None,
                  "turns": samples[-1]["turns"] if samples else 0, "turns_done": samples[-1]["turns_done"] if samples else 0}
        with open(os.path.join(self.out, "report.json"), "w") as handle:
            json.dump(result, handle, indent=1)
        lines = [f"# cmux-next readiness soak: {'PASS' if result['ok'] else 'FAIL'}", "",
                 f"Build {self.setup.get('identity', {}).get('build')} ({self.setup.get('identity', {}).get('version')}), "
                 f"{hours} h, {self.setup.get('agents')} agents ({result['turns_done']}/{result['turns']} turns done), "
                 f"{self.setup.get('terminals')} terminals, {self.setup.get('browsers')} {self.setup.get('browser_engine', '')} browser tabs.", ""]
        lines += [f"- FAIL: {failure}" for failure in failures] or ["- No failures."]
        lines += ["", f"Control round trip (snapshot.get): p50 {result['snapshot_ms_p50']} ms, p99 {result['snapshot_ms_p99']} ms.", "",
                  "| Process | Mean CPU % | Max CPU % | Memory first h (MB) | Memory last h (MB) | Wakeups/s |",
                  "| --- | --- | --- | --- | --- | --- |"]
        for kind, row in summary.items():
            lines.append(f"| {kind} | {row['mean_cpu_percent']} | {row['max_cpu_percent']} | {row['footprint_mb_first_hour']} | "
                         f"{row['footprint_mb_last_hour']} | {row['wakeups_per_s_median']} |")
        if self.events:
            lines += ["", "Events:"] + [f"- {e['at']} {e['kind']}: {e['detail']}" for e in self.events]
        with open(os.path.join(self.out, "report.md"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\n".join(lines))
        return result

    def quit(self):
        try:
            with open(self.config, "w") as handle:
                json.dump({"app": {"quitBehavior": "end-everything"}}, handle)
            time.sleep(2)  # soak script: the app reloads cmux.json from its file watcher
            pids = [pid for pid, kind in self.kinds().items() if kind == "app"]
            Client(self.socket, timeout=10).call("action.run", {"action": "quit", "wait": False})
            wait(lambda: not any(run("kill", "-0", str(pid)).returncode == 0 for pid in pids), 90)
        except (OSError, ValueError, KeyError) as error:
            say(f"quit: {error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="a copy of a tagged cmux-next app (bundle com.cmuxterm.app.debug.<tag>)")
    parser.add_argument("--socket", help="the app's control socket (default /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--agents", type=int, default=10)
    parser.add_argument("--terminals", type=int, default=10)
    parser.add_argument("--browsers", type=int, default=4)
    parser.add_argument("--sample", type=float, default=60)
    parser.add_argument("--turn-every", type=float, default=300)
    parser.add_argument("--warmup", type=float, default=900, help="seconds before the first-hour memory baseline")
    parser.add_argument("--hang-after", type=float, default=10)
    parser.add_argument("--max-growth-mb", type=float, default=300)
    parser.add_argument("--max-growth-percent", type=float, default=25)
    parser.add_argument("--max-app-cpu", type=float, default=10)
    parser.add_argument("--max-daemon-cpu", type=float, default=5)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "readiness-soak"))
    args = parser.parse_args()
    soak = Soak(args)
    soak.preflight()
    teardown = TagTeardown(soak.app, acpmux_home=soak.acpmux_home, acpmux_socket=soak.acp.path, log=say)
    teardown.install()
    result = {"ok": False}
    try:
        soak.launch()
        soak.start_terminals()
        soak.start_browsers()
        soak.start_agents()
        say(f"setup: {json.dumps(soak.setup)}")
        soak.loop()
    finally:
        try:
            result = soak.report()
        finally:
            soak.quit()
            teardown.end()
            shutil.rmtree(soak.work, ignore_errors=True)
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
