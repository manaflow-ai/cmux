#!/usr/bin/env python3
"""Lifecycle sweep with traps (p02-threads 307, RUN-12 in plans/cmux-next/chrome-parity/p02-threads.md): the app's own
lifecycle, not its actions (every-action-sweep.py has those, RUN-1), on a tagged Debug cmux-next app with the
blocking detector's traps on. Not a CI gate: a fleet run an agent does (T2, `cmux-ci run --class exclusive`).

Three launches of one tag, each read once (`debug.blocking`, with reset) before it ends:

  cold          launch-cold from an empty saved session (BenchApp's fresh state); then
                session         a light workspace: a Chromium page and a terminal (perf-stress-session.py build_light)
                sleep-wake      `debug.simulate.wake {phase: sleep}`, then `{phase: wake}`: the NSWorkspace sleep, screens
                                sleep, wake and screens wake notices, in macOS's order, on the center the app observes
                display         `debug.simulate.display`: NSApplication.didChangeScreenParametersNotification
                appearance      `debug.appearance` dark, light, then system (the app's own appearance, the terminal theme
                                and the chrome follow it)
                daemon-kill     SIGKILL to the app's cmux-tui daemon (`debug.daemon` pid, checked to run from this
                                bundle); the app must start a new one and reconnect (`debug.daemon` connected, new pid)
                chromium-crash  SIGKILL to the app's Chromium renderer helpers and any Chromium Host process of this
                                bundle; the app must keep answering (`debug.crashes` is kept in the row)
                quit            the person's Quit that keeps the sessions (quitKeepSessions): the daemon stays
  warm          launch-warm with the saved session and the running daemon; then
                update-install  `debug.updater {action: stage}`, then `{action: relaunch}`: the updater's relaunch hook
                                and NSApp.terminate, exactly as Sparkle does before it installs; the bundle is the same
  after-update  launch-after-update: what Sparkle's relaunch opens (the saved session, the daemon kept); then
                quit-end        Quit and End Sessions (quitEndSessions), then the tag's teardown

Every step clears `debug.hangs` first and keeps its stalls (count, longest) after, and checks the app still answers
(`system.ping`). A step whose app exited, did not answer, or whose recovery did not happen fails (`failed_steps`).

Blocking sites: the launches' reads, the detector's trap lines in OUT/app.log (`Fatal error: blocking ...`), and its
fault lines in the unified log (`log stream` over subsystem com.cmuxterm.app.next, category blocking, kept in
OUT/blocking.log). A launch's table ends with it, so a site its read does not list (a quit path, an exit, the update
relaunch) comes from the fault line its first call logged; in trap mode that also finds the kinds that never trap
(lock-wait, wrong-lane, lane-sync). The sites group by (fileID, kind, context) into one task per module,
p02-threads-R-lifecycle-<Module> (OUT/blocking-tasks.json, the MQ-1 recipe; blocking_sites.py, shared with the
every-action sweep).

--blocking-report=trap (the default, RUN-12): CMUX_BLOCKING_TRAP=1 and CMUX_BLOCKING_TRAP_POOL=1 at every launch; the
run exits BLOCKING_EXIT (5) unless every launch was read in trap mode with 0 traps, 0 sites, 0 overflow and no exit
or quit on SIGTRAP, and the fault log ran the whole run (without it the sites after each read are not checked).
--blocking-report=record files the sites (MQ-10) and never exits on them. Either mode exits
STEP_EXIT (3) when a step failed (and the blocking verdict is clean). On a non-zero exit the report goes into the step
log (lifecycle.md, then one LIFECYCLE-REPORT line of JSON): the controller returns --artifact files only for a step
that passes.

Outputs: OUT/lifecycle.json, OUT/lifecycle.md, OUT/blocking-tasks.json, OUT/blocking/<launch>-<n>.json, OUT/app.log.

Fleet (an owned mini's console; the allowlisted entry builds the tagged Debug app at the ref):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --key KEY --timeout 3600 --artifact artifacts/split-spring/report.json --arg=--suite=lifecycle \\
    [--arg=--blocking-report=record]

Usage: lifecycle-sweep.py --app APP --tag TAG --out DIR [--json PATH] [--blocking-report trap|record]
       [--skip step,step] [--settle 2] [--app-env NAME=VALUE]...
       lifecycle-sweep.py --plan-only --out DIR   (no app, Linux too: the launches and steps it would run)
--skip leaves out steps between a launch and its end (and update-install, then the warm launch quits as `quit`
does); a run with a skip is partial: its verdict is not RUN-12.
"""
import argparse, json, os, re, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from blocking_sites import (BLOCKING_ENV, BLOCKING_LOG_PREDICATE, blocking_fault, blocking_read_problem,  # noqa: E402
                            blocking_section, blocking_traps)

# (launch, the step that starts it, the steps on it, the step that ends it), in run order.
PLAN = (
    ("cold", "launch-cold", ("session", "sleep-wake", "display", "appearance", "daemon-kill", "chromium-crash"), "quit"),
    ("warm", "launch-warm", (), "update-install"),
    ("after-update", "launch-after-update", (), "quit-end"),
)
STEPS = tuple(step for _, start, middle, end in PLAN for step in (start, *middle, end))
SKIPPABLE = tuple(step for _, _, middle, _ in PLAN for step in middle) + ("update-install",)
# What each step does, for --plan-only and lifecycle.md.
DOES = {
    "launch-cold": "launch from an empty saved session; ready = a window answers debug.windows",
    "session": "a light workspace with a Chromium page and a terminal (perf-stress-session build_light)",
    "sleep-wake": "debug.simulate.wake sleep, then wake (NSWorkspace sleep and wake notices)",
    "display": "debug.simulate.display (NSApplication.didChangeScreenParametersNotification)",
    "appearance": "debug.appearance dark, light, system",
    "daemon-kill": "SIGKILL the cmux-tui daemon; a new daemon and the app reconnected",
    "chromium-crash": "SIGKILL the Chromium renderer helpers and Chromium Host processes; the app still answers",
    "quit": "quitKeepSessions; the app exits 0, the daemon keeps running",
    "launch-warm": "launch with the saved session and the running daemon",
    "update-install": "debug.updater stage, then relaunch (the updater's relaunch hook and terminate); the app exits 0",
    "launch-after-update": "launch as Sparkle's relaunch opens it (the saved session, the daemon kept)",
    "quit-end": "quitEndSessions; the app exits 0, then the tag's teardown",
}
LAUNCH_STEPS = {start: name for name, start, _, _ in PLAN}
END_STEPS = {end: name for name, _, _, end in PLAN}

# The exit status of a run with a failed step (the blocking verdict clean): the lifecycle did not hold.
STEP_EXIT = 3
# The exit status of a trap run that is not RUN-12 clean (blocking_section's run12 problems).
BLOCKING_EXIT = 5
REPORT_LINE = "LIFECYCLE-REPORT"
WINDOW = (40, 40, 1440, 900)
# How long the daemon and the app get to come back after the daemon's SIGKILL (restore-journey.py's daemon variant).
RECONNECT_S = 90.0
# How long a quit, an update relaunch or a crash recovery gets before the step fails.
QUIT_S = 30.0
ANSWER_S = 10.0


def note(text):
    print(text, flush=True)


def wait(predicate, seconds, step=0.25, sleep=time.sleep, clock=time.monotonic):
    """The first truthy predicate() within `seconds` (polled every `step`), or None."""
    deadline = clock() + seconds
    while True:
        value = predicate()
        if value:
            return value
        if clock() >= deadline:
            return None
        sleep(step)  # test script: a bounded poll of the app this script started


def process_table():
    """{pid: (ppid, command)} of every process (`ps -A`)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows[int(parts[0])] = (int(parts[1]), parts[2])
    return rows


def chromium_victims(rows, app_pid, bundle):
    """The processes chromium-crash ends: the app's Chromium renderer helpers (its children named `... Helper
    (Renderer)`, AppProcesses.helperKind) and every Chromium Host process run from `bundle` (cef-helper-app-DESIGN.md).
    [(pid, kind)], sorted; never a process outside this app."""
    found = []
    for pid, (ppid, command) in rows.items():
        if ppid == app_pid and " Helper (Renderer)" in command:
            found.append((pid, "renderer"))
        elif command.startswith(bundle + "/") and "Chromium Host" in command and pid != app_pid:
            found.append((pid, "chromium-host"))
    return sorted(found)


class BlockingLog:
    """`log stream` of the detector's fault lines (BLOCKING_LOG_PREDICATE), read on a thread into `sites`
    [(pid, site)] and kept in `path`. Not live where there is no `log` (Linux, a test): `error` says why."""

    ATTACHED = "Filtering the log data"  # log stream's first line once its predicate is in place

    def __init__(self, path, popen=subprocess.Popen):
        self.path, self.process, self.thread, self.error, self.live = path, None, None, None, False
        self.popen = popen
        self.sites, self.lines, self.pids = [], 0, set()

    def start(self):
        import threading
        try:
            self.handle = open(self.path, "w")
            self.process = self.popen(["/usr/bin/log", "stream", "--style", "ndjson", "--predicate",
                                       BLOCKING_LOG_PREDICATE], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True)
        except OSError as error:
            self.error = str(error)
            return self
        first = self.process.stdout.readline()
        if not first.startswith(self.ATTACHED) or self.process.poll() is not None:
            # A refused predicate or a missing privilege: log prints why (stderr is merged) and exits.
            self.error = f"log stream did not attach: {first.strip()[:200] or 'no output'}"
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=10)
            self.process = None
            self.handle.close()
            return self
        self.handle.write(first)
        self.live = True
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        return self

    def read(self):
        for line in self.process.stdout:
            self.handle.write(line)
            self.take(line)

    def take(self, line):
        """One ndjson line: a fault line of one of this run's apps becomes a site."""
        if not line.startswith("{"):
            return
        try:
            event = json.loads(line)
        except ValueError:
            return
        site = blocking_fault(event.get("eventMessage"))
        if site and event.get("processID") in self.pids:
            self.lines += 1
            self.sites.append((event["processID"], site))

    def stop(self):
        if not self.process:
            return
        code = self.process.poll()
        if code is not None:  # it ended before the run did: the fault lines after that are lost
            self.live = False
            self.error = f"log stream exited during the run (code {code})"
        self.process.send_signal(signal.SIGINT)  # our own log stream child: it flushes and exits
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.thread.join(timeout=10)
        self.handle.close()

    def report(self):
        return {"live": self.live, "error": self.error, "sites": self.lines}


def unread_sites(reads, logged):
    """The fault-log sites (`logged`: [(pid, {kind, context, location})]) no read of their launch lists: what ran after
    the read (the quit, an update relaunch) or in a launch that ended unread. One read-shaped entry per launch with
    such sites (`source: log`, the launch's own mode), so blocking_section groups and judges them with the reads."""
    def key(site):
        return (site.get("location"), site.get("kind"), site.get("context") or "main")
    entries = []
    for read in reads:
        reply = read.get("reply") if isinstance(read.get("reply"), dict) else {}
        listed = {key(s) for s in reply.get("sites") or []}
        fresh, seen = [], set()
        for pid, site in logged:
            if pid == read.get("pid") and key(site) not in listed and key(site) not in seen:
                seen.add(key(site))
                fresh.append(dict(site, count=1))
        if fresh:
            mode = reply.get("mode") if not blocking_read_problem(reply, None) else None
            entries.append({"session": f"{read.get('session')} after its read", "launch": read.get("launch"),
                            "pid": read.get("pid"), "exit": None, "source": "log",
                            "reply": {"compiled_in": True, "mode": mode or read.get("asked_mode"),
                                      "pool_mode": reply.get("pool_mode") or mode or read.get("asked_mode"),
                                      "overflow": 0, "sites": fresh}})
    return entries


class Sweep:
    """One run of PLAN. Its seams (the launch, the socket, the process table, signals, sleep) are injected: main()
    passes the real ones, the tests fakes."""

    def __init__(self, opts, out, make_bench, teardown, stress_module, blocking_log, rpc_at,
                 table=process_table, kill=os.kill, sleep=time.sleep, clock=time.monotonic):
        self.opts, self.out = opts, out
        self.make_bench, self.teardown, self.stress_module = make_bench, teardown, stress_module
        self.log, self.rpc_at = blocking_log, rpc_at
        self.table, self.kill, self.sleep, self.clock = table, kill, sleep, clock
        self.skip = set(opts.skip)
        self.bench = None
        self.launch_name = None
        self.launches, self.rows, self.reads = [], [], []

    # Plumbing.

    def rpc(self, method, params=None, timeout=60):
        if self.bench is None:
            return {"error": "no app", "unreachable": True}
        return self.rpc_at(self.bench.socket, method, params, timeout)

    def alive(self):
        return self.bench is not None and self.bench.process is not None and self.bench.process.poll() is None

    def answers(self):
        """The app runs and answers `system.ping` within ANSWER_S."""
        return self.alive() and wait(lambda: not error_of(self.rpc("system.ping", timeout=5)), ANSWER_S,
                                     sleep=self.sleep, clock=self.clock)

    def settle(self):
        self.sleep(self.opts.settle)  # test script: the observers' follow-up work lands before the next read

    def wait(self, predicate, seconds, step=0.25):
        return wait(predicate, seconds, step, sleep=self.sleep, clock=self.clock)

    def environment(self):
        env = {"CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_AGENT_PANE_MOCK": "1", "CMUX_NEXT_CHIEF_ISOLATED": "1",
               "ACPMUX_AGENT_LAUNCH": "deny", **BLOCKING_ENV[self.opts.blocking_report]}
        for item in self.opts.app_env:
            name, equals, value = item.partition("=")
            if not equals or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise SystemExit(f"lifecycle: --app-env takes NAME=VALUE (got {item!r})")
            env[name] = value
        return env

    # The run.

    def run(self):
        for name, start, middle, end in PLAN:
            if not self.launch(name, start):
                for step in (*middle, end):
                    if step not in self.skip:
                        self.fail_row(step, name, "its launch did not come up")
                continue
            for step in middle:
                if step not in self.skip:
                    self.step(step, getattr(self, "do_" + step.replace("-", "_")))
            self.read_blocking()
            self.end(end)
        return self

    def launch(self, name, step):
        """`step` of launch `name`: a BenchApp launch (fresh state only for the cold one). False when it did not
        come up (the row says why; LaunchError is a SystemExit with the launch's report)."""
        self.launch_name = name
        began = self.clock()
        bench = self.make_bench(self.opts.app, out=self.out, env=self.environment(), window=WINDOW, screen="0",
                                log_name="app.log", teardown=False, fresh_state=(name == "cold"))
        self.bench = bench
        record = {"name": name, "pid": None, "fresh_state": name == "cold", "ready_seconds": None, "exit": None}
        self.launches.append(record)

        def started(process):
            record["pid"] = process.pid
            self.log.pids.add(process.pid)
            self.teardown.remember()  # arms end() for this launch, also when it then fails
        try:
            bench.launch(timeout=180, on_start=started)
        except SystemExit as error:  # bench_launch.LaunchError: the reason is in its report and the step log
            self.rows.append({"step": step, "launch": name, "ok": False, "seconds": round(self.clock() - began, 2),
                              "error": f"the launch failed: {error}"[:400]})
            if bench.process is not None:
                self.read_blocking()  # an exit (a trap at launch) is kept unread with its status
                if bench.process.poll() is None:
                    stop_child(bench.process)  # our own child: it never answered (a hung main thread ignores TERM)
                self.launches[-1]["exit"] = self.reads[-1]["quit_exit"] = bench.process.poll()
                self.save_read(self.reads[-1])
            return False
        self.teardown.remember()  # the daemon runs now: its pid and state root
        record["ready_seconds"] = bench.ready_seconds
        self.rows.append({"step": step, "launch": name, "ok": True, "seconds": bench.ready_seconds,
                          "detail": {"fresh_state": name == "cold", "ready_seconds": bench.ready_seconds}})
        self.settle()
        return True

    def step(self, step, body):
        """One step on the running launch: `body()` returns (ok, detail); the stalls it caused are read after it."""
        if not self.alive():
            self.fail_row(step, self.launch_name, f"the app exited ({self.exit_code()})")
            return
        self.rpc("debug.hangs", {"clear": True}, timeout=10)
        began = self.clock()
        try:
            ok, detail = body()
        except Exception as error:  # the run goes on: the row fails and names the error
            ok, detail = False, {"error": repr(error)[:400]}
        seconds = round(self.clock() - began, 2)
        if not self.answers():
            # Whatever the step's own check said: an app that died or hung under a lifecycle event fails it.
            why = f"the app no longer answers (exit {self.exit_code()})" if not self.alive() else "the app no longer answers"
            ok, detail = False, dict(detail, error=why if "error" not in detail else f"{why}; {detail['error']}")
        hangs = self.rpc("debug.hangs", {"limit": 8}, timeout=10) if self.alive() else {}
        self.rows.append({"step": step, "launch": self.launch_name, "ok": bool(ok), "seconds": seconds,
                          "detail": detail, "hangs": hang_summary(hangs)})

    def fail_row(self, step, launch, why):
        self.rows.append({"step": step, "launch": launch, "ok": False, "seconds": None, "error": why})

    def exit_code(self):
        process = self.bench.process if self.bench else None
        return None if process is None else process.poll()

    # Steps on a launch.

    def do_session(self):
        builder = self.stress_module.Stress(self.rpc, log=note, settle=1.0)
        workspace, panes = builder.build_light(kinds=("chromium", "terminal"))
        problems = self.stress_module.cef_problems(self.rpc("debug.cef", timeout=20), builder.web_dev_config)
        return bool(workspace), {"workspace": workspace, "panes": len(panes), "refusals": builder.refusals[:5],
                                 "chromium_unavailable": problems[:4]}

    def do_sleep_wake(self):
        slept = self.rpc("debug.simulate.wake", {"phase": "sleep"}, timeout=20)
        self.settle()
        woke = self.rpc("debug.simulate.wake", {"phase": "wake"}, timeout=20)
        self.settle()
        problem = error_of(slept) or error_of(woke)
        return not problem, {"sleep": slept, "wake": woke, **({"error": problem} if problem else {})}

    def do_display(self):
        reply = self.rpc("debug.simulate.display", timeout=20)
        self.settle()
        return not error_of(reply), {"reply": reply}

    def do_appearance(self):
        seen = {}
        for mode in ("dark", "light", "system"):
            reply = self.rpc("debug.appearance", {"mode": mode}, timeout=20)
            seen[mode] = reply.get("effective") if isinstance(reply, dict) and not error_of(reply) else error_of(reply)
            self.settle()
        return seen["dark"] == "dark" and seen["light"] == "light" and seen["system"] in ("dark", "light"), seen

    def daemon_state(self):
        reply = self.rpc("debug.daemon", timeout=5)
        return reply if isinstance(reply, dict) and not error_of(reply) else {}

    def do_daemon_kill(self):
        state = self.daemon_state()
        pid = int(state.get("pid") or 0)
        command = self.table().get(pid, (0, ""))[1]
        if not pid or not command.startswith(self.bench.app + "/"):
            return False, {"error": f"no daemon of this bundle to kill (debug.daemon pid {pid or None}: {command[:120]!r})"}
        self.kill(pid, signal.SIGKILL)
        began = self.clock()

        def reconnected():
            now = self.daemon_state()
            fresh = int(now.get("pid") or 0)
            return fresh if now.get("connection") == "connected" and fresh and fresh != pid else None
        fresh = self.wait(reconnected, RECONNECT_S)
        if fresh:
            self.teardown.remember()  # the new daemon and its state root, for the last teardown
        detail = {"killed": pid, "new": fresh, "reconnect_seconds": round(self.clock() - began, 2) if fresh else None}
        if not fresh:
            detail["error"] = f"no reconnect to a new daemon within {RECONNECT_S:g} s: {json.dumps(self.daemon_state())[:300]}"
        return bool(fresh), detail

    def do_chromium_crash(self):
        victims = chromium_victims(self.table(), self.bench.process.pid, self.bench.app)
        if not any(kind == "renderer" for _, kind in victims):
            return False, {"error": "no Chromium renderer helper of this app to crash", "found": victims}
        for pid, _ in victims:
            try:
                self.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # it ended with its host
        self.settle()
        crashes = self.rpc("debug.crashes", timeout=20)
        return not error_of(crashes), {"killed": victims, "crashes": crashes}

    # Reads and ends.

    def read_blocking(self):
        """This launch's `debug.blocking` (counts reset after it), once, before its end step: the table ends with the
        launch. A launch that already exited is kept unread, with its exit status."""
        record = self.launches[-1]
        code = self.exit_code()
        reply = self.rpc("debug.blocking", {"reset": True}, timeout=10) if code is None else {"error": f"the app exited ({code})"}
        read = {"session": record["name"], "launch": len(self.launches), "pid": record["pid"], "exit": code,
                "asked_mode": self.opts.blocking_report, "reply": reply}
        self.reads.append(read)
        self.save_read(read)

    def save_read(self, read):
        os.makedirs(os.path.join(self.out, "blocking"), exist_ok=True)
        with open(os.path.join(self.out, "blocking", f"{read['session']}-{read['launch']}.json"), "w") as f:
            json.dump(read, f, indent=1, default=str)

    def end(self, step):
        """The launch's end step (`quit`, `update-install` or `quit-end`); its exit status goes on the launch's read
        (`quit_exit`), so a trap while it ends counts. The tag's teardown runs after the last one."""
        if step == "update-install" and step in self.skip:
            step = "quit"
        began = self.clock()
        if not self.alive():
            self.fail_row(step, self.launch_name, f"the app exited before it ({self.exit_code()})")
        else:
            reply = self.end_input(step)
            exited = self.wait(lambda: self.bench.process.poll() is not None, QUIT_S)
            code = self.exit_code()
            if not exited:
                stop_child(self.bench.process)  # our own child only
            ok = bool(exited) and code == 0
            row = {"step": step, "launch": self.launch_name, "ok": ok, "seconds": round(self.clock() - began, 2),
                   "detail": {"reply": reply, "exit": code if exited else f"still running after {QUIT_S:g} s"}}
            if not ok:
                row["error"] = f"exit {code}" if exited else f"did not exit within {QUIT_S:g} s"
            self.rows.append(row)
        self.launches[-1]["exit"] = self.exit_code()
        self.reads[-1]["quit_exit"] = self.exit_code()
        self.save_read(self.reads[-1])
        if step == "quit-end":
            self.teardown.end()

    def end_input(self, step):
        if step == "update-install":
            staged = self.rpc("debug.updater", {"action": "stage"}, timeout=20)
            if error_of(staged):
                return {"stage": staged}
            # The reply may be lost: the app closes its socket as it quits. The exit is the answer.
            return {"stage": staged, "relaunch": self.rpc("debug.updater", {"action": "relaunch"}, timeout=10)}
        action = "quitEndSessions" if step == "quit-end" else "quitKeepSessions"
        return self.rpc("action.run", {"action": action, "args": {}, "focus": False, "origin": "script"}, timeout=10)


def stop_child(process):
    """End our own launched app: TERM (the app's normal quit), then KILL when it has not exited after QUIT_S (a
    hung main thread never handles the TERM)."""
    process.terminate()
    try:
        process.wait(timeout=QUIT_S)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def error_of(reply):
    if isinstance(reply, dict) and reply.get("error"):
        error = reply["error"]
        if isinstance(error, dict):
            return f"{error.get('code', '')}: {error.get('message', '')}"[:240]
        return str(error)[:240]
    return None


def hang_summary(hangs):
    """debug.hangs: the stall count and the longest stall (ms)."""
    if not isinstance(hangs, dict) or error_of(hangs):
        return {"count": None, "max_ms": None}
    return {"count": hangs.get("count"), "max_ms": round(hangs.get("max_ms") or 0, 2)}


def report_of(sweep, mode, traps, log_report, env):
    """The run's report: the steps, the launches, the blocking section (with RUN-12's verdict in trap mode) and the
    failed steps."""
    reads = sweep.reads + unread_sites(sweep.reads, sweep.log.sites)
    partial = bool(sweep.skip)
    section = blocking_section(mode, reads, traps, partial=partial, sweep="lifecycle")
    if not log_report["live"]:
        section["note"] = f"no fault log ({log_report['error']}): sites after each launch's read are not filed"
        run12 = section.get("run12")
        if run12 is not None:  # the quits and the update relaunch were not checked: no RUN-12 coverage
            run12["problems"].append(f"no fault log ({log_report['error']}): sites after each read are not checked")
            run12["clean"] = False
    return {"env": env, "mode": mode, "partial": partial, "skipped": sorted(sweep.skip), "launches": sweep.launches,
            "steps": sweep.rows, "failed_steps": [r["step"] for r in sweep.rows if not r["ok"]],
            "log_stream": log_report, "blocking": section}


def exit_status(report):
    run12 = (report.get("blocking") or {}).get("run12")
    if run12 and not run12["clean"]:
        return BLOCKING_EXIT
    return STEP_EXIT if report.get("failed_steps") else 0


def markdown(report):
    section = report.get("blocking") or {}
    run12 = section.get("run12")
    lines = [f"# Lifecycle sweep ({report['mode']})", "",
             f"sha {report['env'].get('sha', '?')}, host {report['env'].get('host', '?')}, macOS "
             f"{report['env'].get('macos', '?')}" + (f"; skipped {', '.join(report['skipped'])} (partial, not RUN-12)"
                                                     if report.get("partial") else ""), ""]
    if run12:
        verdict = "clean" if run12["clean"] else "NOT clean: " + "; ".join(run12["problems"])
        lines += [f"RUN-12{'' if run12['whole_catalog'] else ' (partial run)'}: {verdict}", ""]
    if report["failed_steps"]:
        lines += [f"Failed steps: {', '.join(report['failed_steps'])}", ""]
    lines += ["| launch | step | ok | seconds | hangs | detail |", "|---|---|---|---|---|---|"]
    for row in report["steps"]:
        hangs = row.get("hangs") or {}
        detail = row.get("error") or json.dumps(row.get("detail") or {}, default=str)
        lines.append(f"| {row['launch']} | {row['step']} | {'ok' if row['ok'] else 'FAILED'} | {row.get('seconds')} | "
                     f"{hangs.get('count', '')} / {hangs.get('max_ms', '')} ms | {detail[:200].replace('|', '/')} |")
    lines += ["", f"Blocking: {len(section.get('groups') or [])} site group(s), {len(section.get('traps') or [])} trap(s), "
                  f"overflow {section.get('overflow', 0)}; fault log {json.dumps(report['log_stream'])}"]
    if section.get("note"):
        lines += ["", section["note"]]
    if section.get("unread"):
        lines += ["", "Launches whose sites do not count:", ""] + [f"- {why}" for why in section["unread"]]
    if section.get("groups"):
        lines += ["", "| task | fileID | lines | kind | context | count | seen in |", "|---|---|---|---|---|---|---|"]
        for task in section["tasks"]:
            for g in task["sites"]:
                lines.append(f"| {task['id']} | {g['file_id']} | {','.join(map(str, g['lines']))} | {g['kind']} | "
                             f"{g['context']} | {g['count']} | {', '.join(g['sessions'])} |")
    return "\n".join(lines) + "\n"


def write_report(report, out, json_path=None):
    for path in {os.path.join(out, "lifecycle.json"), json_path or os.path.join(out, "lifecycle.json")}:
        with open(path, "w") as f:
            json.dump(report, f, indent=1, default=str)
    with open(os.path.join(out, "lifecycle.md"), "w") as f:
        f.write(markdown(report))
    with open(os.path.join(out, "blocking-tasks.json"), "w") as f:
        json.dump({"mode": report["mode"], "tasks": report["blocking"].get("tasks", [])}, f, indent=1)
        f.write("\n")


def plan(skip=()):
    """The launches and steps a run would do, with what each does and whether it is skipped (a skipped
    update-install ends its launch with `quit`, as Sweep.end does)."""
    def steps(start, middle, end):
        end = "quit" if end == "update-install" and end in skip else end
        return [{"step": s, "does": DOES[s], "skipped": s in skip} for s in (start, *middle, end)]
    return [{"launch": name, "steps": steps(start, middle, end)} for name, start, middle, end in PLAN]


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app")
    parser.add_argument("--tag")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--blocking-report", choices=("trap", "record"), default="trap")
    parser.add_argument("--skip", default="", help=f"comma-separated steps to leave out ({', '.join(SKIPPABLE)})")
    parser.add_argument("--settle", type=float, default=2.0, help="seconds the app gets after each lifecycle event")
    parser.add_argument("--app-env", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--plan-only", action="store_true", help="no app: write the plan (OUT/lifecycle-plan.json)")
    opts = parser.parse_args(argv)
    opts.skip = [s for s in opts.skip.split(",") if s]
    unknown = [s for s in opts.skip if s not in SKIPPABLE]
    if unknown:
        parser.error(f"--skip: {', '.join(unknown)} cannot be skipped (only {', '.join(SKIPPABLE)})")
    if "session" in opts.skip and "chromium-crash" not in opts.skip:
        parser.error("--skip session needs --skip chromium-crash too: the crash needs the session's Chromium page")
    if not opts.plan_only and not (opts.app and opts.tag):
        parser.error("--app and --tag are required (unless --plan-only)")
    return opts


def main(argv=None):
    opts = parse(sys.argv[1:] if argv is None else argv)
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    if opts.plan_only:
        steps = plan(opts.skip)
        with open(opts.json or os.path.join(out, "lifecycle-plan.json"), "w") as f:
            json.dump(steps, f, indent=1)
        note(json.dumps(steps, indent=1))
        return 0
    from bench_launch import BenchApp, load_by_path, rpc_at
    from tag_teardown import TagTeardown
    import platform
    stress_module = load_by_path("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    teardown = TagTeardown(opts.app, log=note)
    teardown.install()  # a cancelled step (TERM, HUP) still runs the finally below
    app_log = os.path.join(out, "app.log")
    log_start = os.path.getsize(app_log) if os.path.exists(app_log) else 0  # app.log is appended to: this run's part
    blocking_log = BlockingLog(os.path.join(out, "blocking.log")).start()
    sha = os.environ.get("CMUX_CI_SHA") or subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True,
                                                          text=True).stdout.strip()
    env = {"host": os.uname().nodename, "macos": platform.mac_ver()[0], "machine": platform.machine(), "sha": sha,
           "app": opts.app, "tag": opts.tag}
    sweep = Sweep(opts, out, BenchApp, teardown, stress_module, blocking_log, rpc_at)
    try:
        sweep.run()
    finally:
        if sweep.alive():  # a run cut short: never leave this tag's app or daemons behind
            sweep.bench.process.terminate()
        teardown.end()
        sweep.sleep(2)  # test script: the last launch's fault lines reach the log stream before it stops
        blocking_log.stop()
    report = report_of(sweep, opts.blocking_report, blocking_traps(app_log, log_start), blocking_log.report(), env)
    write_report(report, out, opts.json)
    status = exit_status(report)
    note(f"lifecycle: wrote {os.path.join(out, 'lifecycle.json')} and lifecycle.md (exit {status})")
    if status:
        note(markdown(report))
        note(f"{REPORT_LINE} {json.dumps(report, default=str)}")
    return status


if __name__ == "__main__":
    sys.exit(main())
