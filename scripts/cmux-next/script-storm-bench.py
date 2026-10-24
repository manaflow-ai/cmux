#!/usr/bin/env python3
"""The person's input and frames while a script storms cmux (Lawrence 2026-10-24: "people will script cmux a lot more
than chrome ... imagine a bunch of scripted sidebar reorders or pane movement, new columns ... esp in backgrounded
workspaces, we want it from first principles not to block anything at all").

Launches the tagged app (bench_launch.py: no activation, scratch config, isolated Chief, the typing probe, the hang
watchdog at 8 ms), builds the session (light: --background workspaces of one terminal; stress: the STRESS session of
perf-stress-session.py, its 10 busy terminals in background workspaces, so no measured-workspace terminal prints while
the person types), and gives each of --background background workspaces two panes and a spare tab. Then, per phase,
the person types --samples keys into a terminal of the shown workspace (`debug.key` stamped right before the send on
an open control connection, so the wait for the main thread counts) and presses Cmd-D / Cmd-W --splits times (each
split checked: a new focused pane in the measured workspace, closed again, the typed tab still there), while:

  idle     nothing else runs
  script   a script process (this file with --storm-worker, so the person's keys come from a process with no busy
           threads) drives cmux, open loop, at --rates ops per second, each kind on its own connection:
             reorder     move-workspace of a random background workspace to a random index (daemon)
             move        move-tab of the spare tab between the two panes of a background workspace (daemon)
             column      one op per step in the next background workspace: new-pane-right / new-row while that
                         workspace has fewer than --live-columns script panes and the storm fewer than
                         --max-live-terminals, else close-tabs (end_terminals) of the oldest live one; closed from
                         the create's reply, every one closed again when the phase ends (daemon)
             rename      rename-surface of a background tab (daemon)
             app-rename  action.run renameTab (wait: false) of a background tab: the app-side load (control socket)

Per session and phase: key to frame p50/p95/p99/max (the probe's contents_ms, see KEY_COLUMN), split input-to-commit
(`action.input_to_commit` signposts, perf-signposts.py), display frames (debug.frames: refresh, missed vsyncs over 1.5
periods, main-thread busy per frame), main-thread stalls over 8 ms (debug.hangs), the control work queue
(debug.queue), and per op kind the asked rate, the applied rate (ok replies per second), refusals and reply latency.
A phase whose storm was not applied (an applied rate under MIN_APPLIED_SHARE of the asked one, refusals over
MAX_REFUSED_SHARE), whose keys closed under MIN_SAMPLE_SHARE of --samples, or whose splits failed their check is
reported "invalid" with its reasons and no key numbers. The report states host, macOS and display refresh. No gate: a
measurement (perf cron runs it opportunistically).

Terminals are a shared host resource (kern.tty.ptmx_max 511, shared by every agent): the setup and every script phase
refuse to start when the PTYs in use plus the ones they open would reach bench_cli_storm's MAX_PTY_LIMIT.

  script-storm-bench.py --app APP --out DIR [--sessions light,stress] [--seconds 15] [--samples 120]
      [--rates reorder=1000,move=200,column=100,rename=500,app-rename=640] [--background 50] [--json FILE]

The STRESS session is built by perf-stress-session.py, which checks its shape: a session of another shape reports
"STRESS shape missed" and no numbers. The app launches through bench_launch.py.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=script-storm [--arg=--vdisplay=120] [--arg=--sessions=light]
"""
import argparse, collections, csv, importlib.util, json, os, random, socket, statistics, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Validity of a phase. A storm that applied less than 90% of an asked rate, or had more than 1% of its ops refused,
# is not the asked load; keys that closed fewer than 90% of their samples do not describe the phase.
MIN_APPLIED_SHARE = 0.9
MAX_REFUSED_SHARE = 0.01
MIN_SAMPLE_SHARE = 0.9
# A split that has not made (or closed) its pane after 5 s, 500 times the 10 ms target, failed.
SPLIT_DEADLINE_S = 5.0
# Bounded waits for the script process: its connections' first replies, and the end-of-phase closes.
STORM_START_DEADLINE_S = 20.0
STORM_DRAIN_DEADLINE_S = 30.0
# The probe column reported as key to frame: the first `setContents:` on a terminal IOSurfaceLayer after the echo's
# parse (TypingFrameProbe). It is not bound to the typed surface and is set before Core Animation commits that
# run-loop turn: work later in the same turn (the storm's snapshot and sidebar work) is not in it. A surface-bound
# mark at the commit after contents needs the probe change (TypingLatencyProbe); until then this column stands.
KEY_COLUMN = "contents_ms"


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


def error_code(message):
    error = message.get("error")
    return str(error.get("code") if isinstance(error, dict) else error)[:80]


def daemon_frame(rid, method, params):
    return {"id": rid, "cmd": method, **params}


def control_frame(rid, method, params):
    return {"id": rid, "method": method, "params": params}


class Connection:
    """A pipelined JSON-lines connection (the session daemon's `{"id", "cmd", ...}` or the app's control
    `{"id", "method", "params"}`): `send` never waits for a reply; a reader thread matches replies by id, counts ok
    replies and refusals, records latency, keeps a reply only when `send` asked for it, and calls `on_reply(message,
    context, ok)` for every reply. At most `max_inflight` requests wait unanswered; past that `send` returns None (the
    script is faster than cmux: counted, not queued)."""

    def __init__(self, path, frame, max_inflight, on_reply=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.frame, self.max_inflight, self.on_reply = frame, max_inflight, on_reply
        self.cond = threading.Condition()
        self.write_lock = threading.Lock()
        self.pending, self.kept, self.next_id = {}, {}, 1
        self.latencies, self.refusals = [], {}
        self.sent = self.ok = self.skipped = self.send_failed = self.replied = 0
        self.closed = False
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def send(self, method, params, context=None, keep=False):
        with self.cond:
            if self.closed:
                self.send_failed += 1
                return None
            if len(self.pending) >= self.max_inflight:
                self.skipped += 1
                return None
            rid = self.next_id
            self.next_id += 1
            self.pending[rid] = (time.perf_counter(), context, keep)
        line = (json.dumps(self.frame(rid, method, params)) + "\n").encode()
        try:
            with self.write_lock:
                self.sock.sendall(line)
        except OSError:
            with self.cond:
                self.pending.pop(rid, None)
                self.send_failed += 1
                self.closed = True
                self.cond.notify_all()
            return None
        with self.cond:
            self.sent += 1
        return rid

    def read(self):
        buffer = b""
        while True:
            try:
                chunk = self.sock.recv(1 << 20)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                rid = message.get("id") if isinstance(message, dict) else None
                if rid is None:
                    continue  # an event
                with self.cond:
                    started, context, keep = self.pending.get(rid, (None, None, False))
                    if started is None:
                        continue
                    self.replied += 1
                    self.latencies.append((time.perf_counter() - started) * 1000)
                    ok = message.get("ok") is True
                    if ok:
                        self.ok += 1
                    else:
                        code = error_code(message)
                        self.refusals[code] = self.refusals.get(code, 0) + 1
                # Outside the condition (on_reply takes its owner's lock, which a step holds while it sends), and
                # before the request leaves `pending`: a waiter that sees it answered also sees what on_reply did.
                if self.on_reply:
                    self.on_reply(message, context, ok)
                with self.cond:
                    self.pending.pop(rid, None)
                    if keep:
                        self.kept[rid] = message
                    self.cond.notify_all()
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def wait_reply(self, rid, timeout):
        """The kept reply to `rid`, or None when the connection closed or `timeout` passed first."""
        if rid is None:
            return None
        with self.cond:
            self.cond.wait_for(lambda: rid in self.kept or rid not in self.pending or self.closed, timeout)
            return self.kept.pop(rid, None)

    def wait_until(self, predicate, timeout):
        """Waits (on replies, not a timer) until `predicate()` holds; its value."""
        with self.cond:
            return self.cond.wait_for(lambda: predicate() or self.closed, timeout) and predicate()

    def drain(self, timeout):
        """Waits until every sent request has its reply; whether none is left unanswered."""
        return self.wait_until(lambda: not self.pending, timeout)

    def report(self, seconds, asked):
        with self.cond:
            refused = sum(self.refusals.values())
            return {"asked_per_s": asked, "sent": self.sent, "ok": self.ok,
                    "applied_per_s": round(self.ok / seconds, 1) if seconds else None,
                    "skipped_inflight_full": self.skipped, "send_failed": self.send_failed,
                    "unanswered": len(self.pending), "refused": refused, "refusals": dict(self.refusals),
                    "reply_ms": pct(self.latencies)}

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class Paced(threading.Thread):
    """Calls `step(i)` at `rate` per second, open loop (behind schedule: it catches up, never sleeps), until stopped."""

    def __init__(self, rate, step, on_error):
        super().__init__(daemon=True)
        self.rate, self.step, self.on_error, self.flag, self.calls = rate, step, on_error, threading.Event(), 0

    def run(self):
        start = time.perf_counter()
        while not self.flag.is_set():
            due = start + self.calls / self.rate
            rest = due - time.perf_counter()
            if rest > 0:
                self.flag.wait(rest)  # the script's pace
                continue
            try:
                self.step(self.calls)
            except Exception as error:  # one failed op must not end the storm; it is counted and reported
                self.on_error(error)
            self.calls += 1

    def stop(self):
        self.flag.set()
        self.join(timeout=30)


# The script process (--storm-worker): each op kind owns its connection, its step and its report.


class Load:
    """One op kind: its connection, its paced step and its report."""

    def __init__(self, kind, rate, connection, step):
        self.kind, self.rate, self.connection = kind, rate, connection
        self.errors = collections.Counter()
        self.thread = Paced(rate, step, lambda error: self.errors.update([repr(error)[:120]]))

    def finish(self):
        """After the pacing stopped: what the kind still owes the session (nothing, except the column kind)."""
        return {}

    def report(self, seconds):
        report = self.connection.report(seconds, self.rate)
        report["step_errors"] = dict(self.errors)
        return report


def reorder_load(plan, rng):
    connection = Connection(plan["daemon"], daemon_frame, plan["max_inflight"])
    background, count = plan["background"], plan["workspaces"]
    return Load("reorder", plan["rates"]["reorder"], connection, lambda i: connection.send(
        "move-workspace", {"workspace": rng.choice(background)["handle"], "index": rng.randrange(max(count - 1, 1))}))


def move_load(plan, rng):
    connection = Connection(plan["daemon"], daemon_frame, plan["max_inflight"])
    background = plan["background"]
    where = [0] * len(background)

    def step(i):
        index = i % len(background)
        where[index] ^= 1
        ws = background[index]
        connection.send("move-tab", {"surface": ws["spare"], "pane": ws["panes"][where[index]], "index": 0})
    return Load("move", plan["rates"]["move"], connection, step)


def rename_load(plan, rng):
    connection = Connection(plan["daemon"], daemon_frame, plan["max_inflight"])
    background = plan["background"]
    return Load("rename", plan["rates"]["rename"], connection, lambda i: connection.send(
        "rename-surface", {"surface": rng.choice(rng.choice(background)["tabs"]), "name": f"storm {i}"}))


def app_rename_load(plan, rng):
    connection = Connection(plan["control"], control_frame, plan["max_inflight"])
    ids = [t for ws in plan["background"] for t in ws["tab_ids"]]
    return Load("app-rename", plan["rates"]["app-rename"], connection, lambda i: connection.send(
        "action.run", {"action": "renameTab", "target": f"tab:{rng.choice(ids)}", "args": {"name": f"app storm {i}"},
                       "wait": False, "focus": False, "origin": "script"}))


class ColumnLoad(Load):
    """New panes in background workspaces, each closed again from its create's reply. A terminal counts as live from
    its create's send until its close's ok reply, so the live terminals never pass --live-columns per workspace or
    --max-live-terminals for the storm."""

    def __init__(self, plan, rng):
        self.background = plan["background"]
        self.per_workspace, self.cap = plan["live_columns"], plan["max_live_terminals"]
        self.lock = threading.Lock()
        self.alive = {ws["handle"]: 0 for ws in self.background}  # creating + live + closing, per workspace
        self.live = collections.OrderedDict()  # surface -> workspace handle, oldest first
        self.total = 0
        self.held = self.creates_ok = self.closes_ok = 0
        self.unclosable = []  # surfaces whose close was refused, and creates whose ok reply named no surface
        connection = Connection(plan["daemon"], daemon_frame, plan["max_inflight"], on_reply=self.reply)
        super().__init__("column", plan["rates"]["column"], connection, self.step)

    def reply(self, message, context, ok):
        op, handle, surface = context
        with self.lock:
            if op == "create":
                made = ((message.get("data") or {}).get("surface")) if ok else None
                if made is not None:
                    self.creates_ok += 1
                    self.live[made] = handle
                elif ok:
                    self.unclosable.append({"create_without_surface": handle})  # stays counted live: it may exist
                else:
                    self.alive[handle] -= 1
                    self.total -= 1
            elif ok:
                self.closes_ok += 1
                self.alive[handle] -= 1
                self.total -= 1
            else:
                self.unclosable.append({"close_refused": surface, "code": error_code(message)})

    def oldest(self, handle=None):
        return next((s for s, h in self.live.items() if handle is None or h == handle), None)

    def step(self, i):
        ws = self.background[i % len(self.background)]
        handle = ws["handle"]
        with self.lock:
            if self.alive[handle] < self.per_workspace and self.total < self.cap:
                op, surface = ("new-row" if i % 2 else "new-pane-right"), None
                self.alive[handle] += 1
                self.total += 1
            else:
                # At a limit: close this workspace's oldest pane, or the storm's oldest when only the storm is full.
                surface = self.oldest(handle if self.alive[handle] >= self.per_workspace else None)
                if surface is None:
                    self.held += 1  # every pane here is still being made or closed
                    return
                op = "close-tabs"
                handle = self.live.pop(surface)
        if op == "close-tabs":
            sent = self.connection.send(op, {"surfaces": [surface], "end_terminals": True}, context=("close", handle, surface))
        elif op == "new-row":
            sent = self.connection.send(op, {"pane": ws["panes"][0], "height_permille": 500}, context=("create", handle, None))
        else:
            sent = self.connection.send(op, {"pane": ws["panes"][0]}, context=("create", handle, None))
        if sent is None:
            with self.lock:
                if op == "close-tabs":
                    self.live[surface] = handle
                    self.live.move_to_end(surface, last=False)
                else:
                    self.alive[handle] -= 1
                    self.total -= 1

    def finish(self):
        """Every pane this storm made, closed again: the creates still in flight answered first, then one close each."""
        answered = self.connection.wait_until(lambda: not any(c[0] == "create" for _, c, _ in self.connection.pending.values()),
                                              STORM_DRAIN_DEADLINE_S)
        with self.lock:
            surfaces = list(self.live.items())
            self.live.clear()
        for surface, handle in surfaces:
            if self.connection.send("close-tabs", {"surfaces": [surface], "end_terminals": True},
                                    context=("close", handle, surface)) is None:
                with self.lock:
                    self.unclosable.append({"close_not_sent": surface})
        drained = self.connection.drain(STORM_DRAIN_DEADLINE_S)
        with self.lock:
            return {"creates_answered": bool(answered), "closes_answered": bool(drained),
                    "terminals_left_open": self.total, "unclosable": self.unclosable[:20]}

    def report(self, seconds):
        report = super().report(seconds)
        with self.lock:
            report.update({"creates_ok": self.creates_ok, "closes_ok": self.closes_ok, "held_at_limit": self.held})
        return report


LOADS = {"reorder": reorder_load, "move": move_load, "column": ColumnLoad, "rename": rename_load,
         "app-rename": app_rename_load}


def storm_worker(plan_path):
    """The script: runs every kind of the plan from the first reply on each connection until a line (or EOF) on
    stdin, then closes what it made and prints its report as one JSON line on stdout."""
    with open(plan_path) as handle:
        plan = json.load(handle)
    loads = []
    for index, (kind, rate) in enumerate(sorted(plan["rates"].items())):
        if rate:
            loads.append(LOADS[kind](plan, random.Random(7 + index)))
    for load in loads:
        load.thread.start()
    first = all(load.connection.wait_until(lambda c=load.connection: c.replied > 0, STORM_START_DEADLINE_S) for load in loads)
    started = time.perf_counter()
    print(json.dumps({"running": first, "kinds": [load.kind for load in loads]}), flush=True)
    sys.stdin.readline()
    seconds = time.perf_counter() - started
    for load in loads:
        load.thread.stop()
    report = {"seconds": round(seconds, 2)}
    for load in loads:
        report[load.kind] = {**load.report(seconds), **load.finish()}
        load.connection.close()
    print(json.dumps(report), flush=True)
    return 0


if __name__ == "__main__" and sys.argv[1:2] == ["--storm-worker"]:
    sys.exit(storm_worker(sys.argv[2]))


# The bench.

from bench_launch import BenchApp, LaunchError  # noqa: E402
from bench_cli_storm import MAX_PTY_LIMIT, daemon_socket, ptys_in_use  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag")  # split-spring.sh passes it; the tag comes from the bundle
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--phases", default="idle,script")
parser.add_argument("--seconds", type=float, default=15.0, help="length of each phase's script load")
parser.add_argument("--samples", type=int, default=120)
parser.add_argument("--interval", type=float, default=0.1, help="seconds between keys (one key in flight)")
parser.add_argument("--splits", type=int, default=10, help="Cmd-D then Cmd-W pairs per phase")
parser.add_argument("--rates", default="reorder=1000,move=200,column=100,rename=500,app-rename=640")
parser.add_argument("--background", type=int, default=50, help="background workspaces the script works in")
parser.add_argument("--live-columns", type=int, default=2, help="script-made panes alive per workspace before closing")
# STRESS plus the setup's two terminals per background workspace hold about 190 PTYs; 40 more keeps the host under
# MAX_PTY_LIMIT (300) with room for other agents' sessions. The PTY check refuses a phase that would pass it.
parser.add_argument("--max-live-terminals", type=int, default=40, help="script-made terminals alive in the whole storm")
parser.add_argument("--max-inflight", type=int, default=512, help="unanswered requests per op kind")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
PROBE = os.path.join(OUT, "typing.csv")
RATES = {k: float(v) for k, v in (item.split("=") for item in opts.rates.split(",") if item)}
unknown = sorted(set(RATES) - set(LOADS))
if unknown:
    parser.error(f"--rates: unknown op kinds {unknown} (known: {sorted(LOADS)})")
results = {"host": os.uname().nodename, "opts": vars(opts), "key_column": KEY_COLUMN, "log": [], "runs": []}


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def load_module(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def host_facts():
    facts = {"macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()}
    try:
        shown = json.loads(subprocess.run(["system_profiler", "-json", "SPDisplaysDataType"], capture_output=True,
                                          text=True, timeout=60).stdout or "{}")
        facts["displays"] = [d.get("_spdisplays_resolution") or d.get("spdisplays_resolution")
                             for gpu in shown.get("SPDisplaysDataType", []) for d in gpu.get("spdisplays_ndrvs", [])]
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        facts["displays_error"] = str(error)
    return facts


class PtyRefusal(RuntimeError):
    pass


def pty_guard(what, opening):
    """Refuses `what` when the PTYs in use plus the `opening` it adds would reach MAX_PTY_LIMIT (bench_cli_storm)."""
    in_use = ptys_in_use()
    if in_use + opening >= MAX_PTY_LIMIT:
        raise PtyRefusal(f"{in_use} PTYs in use before {what}; it opens up to {opening} more, reaching {MAX_PTY_LIMIT}")
    return in_use


class Keys:
    """The person's keyboard: one control connection, opened once, used by this process's only thread. Each key's
    timestamp is taken right before its send, so only the app's time counts."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.buffer, self.next_id = b"", 1

    def press(self, key, modifiers=None):
        params = {"key": key}
        if modifiers:
            params["modifiers"] = modifiers
        rid = self.next_id
        self.next_id += 1
        params["timestamp"] = time.clock_gettime(time.CLOCK_UPTIME_RAW)
        self.sock.sendall((json.dumps({"id": rid, "method": "debug.key", "params": params}) + "\n").encode())
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise OSError("control socket closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        reply = json.loads(line)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Session:
    """One app launch: its session built, its background prepared, every phase measured."""

    def __init__(self, name):
        self.name = name
        self.app = BenchApp(opts.app, out=os.path.join(OUT, name),
                            env={"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"},
                            config={"browser": {"defaultEngine": "chromium"}, "appearance": {"backgroundOpacity": 1}},
                            window=(80, 40, 1600, 1000))
        self.rpc = self.app.rpc
        self.builder = load_module("perf_stress_session", "perf-stress-session.py")
        self.stress = None
        self.measured = self.typed_pane = self.typed_tab = None
        self.background = []  # [{"handle", "panes": [pane handles], "spare": surface, "tabs": [surfaces], "tab_ids"}]
        self.daemon_path = None
        self.broken = None  # why the session cannot be measured further (a failed split check)

    def action(self, name, args=None, target=None, focus=True, timeout=60):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def topology(self):
        reply = self.rpc("snapshot.get") or {}
        return (reply.get("topology") or {}) if isinstance(reply, dict) else {}

    def build(self):
        # The busy terminals print in background workspaces: in the measured one they would hand the typing
        # probe frames that are not the typed echo.
        self.stress = self.builder.Stress(self.rpc, log=note, busy_where="elsewhere")
        if self.name == "stress":
            summary = self.stress.build()
            note("STRESS-SESSION " + json.dumps(summary))
            results.setdefault("stress", summary)
            measured = summary.get("measured")
        else:
            self.stress.build_background(count=opts.background, chromium=0)
            measured = self.stress.new_workspace()
            self.stress.show(measured)
        panes = self.stress.panes(self.stress.workspace(measured))
        last = panes[-1]
        self.stress.focus_pane(last["id"])
        tab = next((t for t in reversed(last.get("tabs") or []) if t.get("kind") == "terminal"), None)
        if not tab:
            raise self.builder.StressShapeError(f"the typed pane {last['id']} has no terminal tab")
        self.stress.action("tab.focus", target=f"tab:{tab['id']}")
        self.action("terminal.sendText", {"text": "exec /bin/zsh -f\r"}, focus=False)
        time.sleep(1)  # bench script: the prompt draws
        self.measured, self.typed_pane, self.typed_tab = measured, last["id"], tab["id"]
        return measured

    def prepare_background(self, measured):
        """Two panes and a spare tab in each of --background workspaces that no window shows (daemon commands); waits
        until the app's snapshot shows each of them so."""
        tui = os.path.join(self.app.app, "Contents/Resources/bin/cmux-tui")
        self.daemon_path = daemon_socket(tui, self.app.tag)
        shown = {w.get("workspace") for w in self.topology().get("windows") or []}
        chosen = [w for w in self.topology().get("workspaces") or []
                  if w.get("id") not in shown and w.get("id") != measured][: opts.background]
        pty_guard("the background setup", 2 * len(chosen))
        setup = Connection(self.daemon_path, daemon_frame, 64)
        wanted, refused = set(), []
        try:
            for workspace in chosen:
                panes = self.stress.panes(workspace)
                if not panes:
                    continue
                first = int(panes[0]["handle"])
                steps = (["new-pane-right"] if len(panes) < 2 else []) + ["new-tab"]
                replies = [setup.wait_reply(setup.send(cmd, {"pane": first}, keep=True), 15) for cmd in steps]
                if all((reply or {}).get("ok") is True for reply in replies):
                    wanted.add(workspace.get("id"))
                else:
                    refused.append({cmd: error_code(reply or {"error": "no reply"}) for cmd, reply in zip(steps, replies)})
        finally:
            setup.close()
        if refused:
            note(f"{self.name}: {len(refused)} background setups refused, first {refused[0]}")
        if not wanted:
            raise RuntimeError(f"no background workspace could be prepared ({len(chosen)} chosen)")

        def ready():
            found = []
            for workspace in self.topology().get("workspaces") or []:
                panes = self.stress.panes(workspace) if workspace.get("id") in wanted else []
                spare = next(iter((panes[0].get("tabs") or [])[1:]), None) if len(panes) >= 2 else None
                if spare:
                    found.append((workspace, panes, spare))
            return found if len(found) == len(wanted) else None
        found = self.builder.wait(ready, 30, step=0.1)
        if not found:
            raise RuntimeError(f"{len(wanted)} background workspaces asked; the snapshot never showed all of them "
                               "with two panes and a spare tab")
        for workspace, panes, spare in found:
            tabs = [t for p in panes for t in p.get("tabs") or []]
            self.background.append({"handle": int(workspace["handle"]), "panes": [int(p["handle"]) for p in panes[:2]],
                                    "spare": int(spare["surface"]), "tabs": [int(t["surface"]) for t in tabs],
                                    "tab_ids": [t["id"] for t in tabs]})
        note(f"{self.name}: {len(self.background)} background workspaces prepared")

    # The script.

    def start_storm(self, phase):
        """Starts the script process; returns it once each of its connections has a first reply."""
        live = min(opts.max_live_terminals, opts.live_columns * len(self.background)) if RATES.get("column") else 0
        pty_guard(f"the {phase} storm", live)
        plan = {"daemon": self.daemon_path, "control": self.app.socket, "rates": RATES, "background": self.background,
                "workspaces": len(self.topology().get("workspaces") or []), "live_columns": opts.live_columns,
                "max_live_terminals": opts.max_live_terminals, "max_inflight": opts.max_inflight}
        plan_path = os.path.join(OUT, self.name, f"storm-{phase}.plan.json")
        with open(plan_path, "w") as handle:
            json.dump(plan, handle)
        log = open(os.path.join(OUT, self.name, f"storm-{phase}.log"), "w")
        worker = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--storm-worker", plan_path],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        log.close()
        line = worker.stdout.readline()
        start = json.loads(line) if line.strip() else {}
        if not start.get("running"):
            worker.kill()
            worker.wait()
            raise RuntimeError(f"the script process did not start (first line {line.strip()[:200]!r}; see its log)")
        return worker

    @staticmethod
    def stop_storm(worker):
        out, _ = worker.communicate("stop\n", timeout=STORM_DRAIN_DEADLINE_S * 2 + 60)
        lines = out.strip().splitlines()
        return json.loads(lines[-1]) if lines else {"error": f"the script process exited {worker.returncode} with no report"}

    @staticmethod
    def storm_problems(script):
        problems = []
        for kind, rate in RATES.items():
            if not rate:
                continue
            report = script.get(kind)
            if not isinstance(report, dict):
                problems.append(f"{kind}: no report")
                continue
            applied = report.get("applied_per_s") or 0
            if applied < MIN_APPLIED_SHARE * rate:
                problems.append(f"{kind}: applied {applied}/s of {rate:g}/s asked")
            if report.get("refused", 0) > MAX_REFUSED_SHARE * max(report.get("sent", 0), 1):
                problems.append(f"{kind}: {report.get('refused')} of {report.get('sent')} refused {report.get('refusals')}")
            if report.get("terminals_left_open"):
                problems.append(f"{kind}: {report['terminals_left_open']} script terminals left open")
        return problems

    # The person.

    def probe_rows(self):
        try:
            with open(PROBE) as handle:
                return list(csv.DictReader(handle))
        except OSError:
            return []

    def focus(self):
        return self.topology().get("focus") or {}

    def measured_panes(self):
        return self.stress.panes(self.stress.workspace(self.measured))

    def typed_tab_present(self):
        return any(t.get("id") == self.typed_tab for p in self.measured_panes() for t in p.get("tabs") or [])

    def type_keys(self, keys):
        letters = "abcdefghijklmnopqrstuvwxyz"
        before = len(self.probe_rows())
        for index in range(opts.samples):
            started = time.perf_counter()
            keys.press(letters[index % len(letters)])
            rest = opts.interval - (time.perf_counter() - started)
            if rest > 0:
                time.sleep(rest)  # bench script: one key in flight
        time.sleep(0.5)  # bench script: the last echo's frame lands
        rows = [r for r in self.probe_rows()[before:before + opts.samples] if r.get("complete") == "1" and r.get(KEY_COLUMN)]
        keys.press("u", ["ctrl"])  # clears the typed line (its probe row is not a sample)
        return [float(r[KEY_COLUMN]) for r in rows]

    def splits(self, keys):
        """Cmd-D then Cmd-W, each checked; the problems (the first failure ends the pairs)."""
        for index in range(opts.splits):
            before = {p.get("id") for p in self.measured_panes()}

            def new_focused_pane():
                focus = self.focus()
                if focus.get("workspace") == self.measured and focus.get("pane") not in before:
                    return focus.get("pane")
                return None
            keys.press("d", ["cmd"])
            made = self.builder.wait(new_focused_pane, SPLIT_DEADLINE_S, step=0.02)
            if not made:
                return [f"split {index + 1}: Cmd-D focused no new pane of the measured workspace in {SPLIT_DEADLINE_S:g} s"]
            time.sleep(0.4)  # bench script: the person looks at the new pane
            keys.press("w", ["cmd"])
            if not self.builder.wait(lambda: made not in {p.get("id") for p in self.measured_panes()}, SPLIT_DEADLINE_S, step=0.02):
                return [f"split {index + 1}: Cmd-W did not close the new pane {made} in {SPLIT_DEADLINE_S:g} s"]
            if not self.typed_tab_present():
                return [f"split {index + 1}: the typed tab {self.typed_tab} is gone after Cmd-W"]
            time.sleep(0.4)  # bench script: and goes on
        return []

    def measure(self, phase):
        self.action("pane.focus", target=f"pane:{self.typed_pane}")
        self.action("tab.focus", target=f"tab:{self.typed_tab}")
        invalid = []
        if not self.builder.wait(lambda: self.focus().get("pane") == self.typed_pane, 10, step=0.05) or not self.typed_tab_present():
            invalid.append(f"focus never reached the typed pane {self.typed_pane} with its tab {self.typed_tab}")
        pid = (self.app.running_pids() or [None])[0]
        signposts = None
        save = os.path.join(OUT, self.name, f"signposts-{phase}.ndjson")
        if pid:
            signposts = subprocess.Popen([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(pid),
                                          "--category", "action", "--allow-loss", "--save", save, "--json",
                                          "--seconds", str(int(opts.seconds + opts.samples * opts.interval
                                                               + opts.splits * (0.8 + 2 * SPLIT_DEADLINE_S) + 10))],
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            time.sleep(1)  # bench script: `log stream` attaches before the first key
        worker = self.start_storm(phase) if phase == "script" else None
        self.rpc("debug.hangs", {"clear": True})
        self.rpc("debug.queue", {"reset": True})
        self.rpc("debug.frames", {"action": "start"})
        started = time.perf_counter()
        keys = Keys(self.app.socket)
        try:
            typed = self.type_keys(keys)
            split_problems = self.splits(keys)
        finally:
            keys.close()
        if worker:
            rest = opts.seconds - (time.perf_counter() - started)
            if rest > 0:
                time.sleep(rest)  # bench script: the storm runs its full length
        elapsed = time.perf_counter() - started
        frames = self.rpc("debug.frames", {"action": "stop"}, timeout=20)
        hangs = self.rpc("debug.hangs", {"limit": 12}, timeout=20)
        queue = self.rpc("debug.queue", timeout=20)
        script = self.stop_storm(worker) if worker else None
        if script is not None:
            invalid += [f"storm not applied: {p}" for p in self.storm_problems(script)]
        if len(typed) < MIN_SAMPLE_SHARE * opts.samples:
            invalid.append(f"{len(typed)} of {opts.samples} keys closed a probe row")
        if split_problems:
            invalid += split_problems
            self.broken = split_problems[0]
        split_rows = None
        if signposts:
            out, _ = signposts.communicate(timeout=opts.seconds + 120)
            try:
                report = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
                rows = report.get("rows") or []
                # The person's Cmd-D / Cmd-W (whatever ids they bind) and every person action together.
                split_rows = [r for r in rows if r.get("name") == "action.input_to_commit"]
            except ValueError:
                split_rows = {"unparsed": out[-2000:]}
        entry = {"session": self.name, "phase": phase, "seconds": round(elapsed, 1), "invalid": invalid,
                 "key_to_frame_ms": None if invalid else pct(typed), "key_column": KEY_COLUMN,
                 "keys": opts.samples, "keys_closed": len(typed),
                 "split_input_to_commit": None if split_problems else split_rows, "frames": frames,
                 "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms", "records")}
                 if isinstance(hangs, dict) else hangs,
                 "queue": queue, "script": script}
        k = entry["key_to_frame_ms"] or {}
        f = frames if isinstance(frames, dict) else {}
        applied = {kind: (v.get("applied_per_s"), v.get("asked_per_s"), v.get("refused"))
                   for kind, v in (script or {}).items() if isinstance(v, dict)}
        note(f"{self.name}.{phase}: "
             + (f"INVALID ({'; '.join(invalid)}); " if invalid else
                f"key-to-frame ({KEY_COLUMN}) p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
                f"(n={k.get('n')} of {opts.samples}); ")
             + f"frames missed {f.get('missed')} of {f.get('frames')} at {f.get('refresh_ms')} ms; "
             f"stalls {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}"
             + (f"; script applied/asked/refused per kind {json.dumps(applied)}" if script else ""))
        results["runs"].append(entry)
        if opts.json:
            json.dump(results, open(opts.json, "w"), indent=1)

    def run(self):
        try:
            self.app.launch()
        except LaunchError as error:
            note(f"{self.name}: launch failed: {error}")
            return
        try:
            time.sleep(3)  # bench script: launch work settles
            methods = (self.rpc("system.capabilities") or {}).get("methods") or []
            missing = [m for m in ("action.run", "snapshot.get", "debug.key", "debug.frames") if m not in methods]
            if missing:
                note(f"{self.name}: the app has no {missing}; nothing measured")
                results["runs"].append({"session": self.name, "phase": "build", "missing_methods": missing})
                return
            try:
                measured = self.build()
            except Exception as error:  # the builder's StressShapeError (and any refusal while building)
                if type(error).__name__ != "StressShapeError":
                    raise
                # Another shape is never measured as STRESS.
                note(f"{self.name}: STRESS shape missed: {error}")
                results["runs"].append({"session": self.name, "phase": "build", "stress_shape_missed": str(error)[:2000]})
                return
            try:
                self.prepare_background(measured)
            except (PtyRefusal, RuntimeError) as error:
                note(f"{self.name}: background not prepared: {error}; nothing measured")
                results["runs"].append({"session": self.name, "phase": "build", "background_problem": str(error)[:2000]})
                return
            for phase in opts.phases.split(","):
                if self.broken:
                    note(f"{self.name}.{phase}: not measured: an earlier phase broke the layout ({self.broken})")
                    results["runs"].append({"session": self.name, "phase": phase, "invalid": [f"not measured: {self.broken}"]})
                    continue
                try:
                    self.measure(phase)
                except Exception as error:  # one phase failing must not hide the others; it is reported
                    note(f"{self.name}.{phase}: failed: {error!r}")
                    results["runs"].append({"session": self.name, "phase": phase, "invalid": [f"failed: {error!r}"[:2000]]})
        finally:
            self.app.stop()


def main():
    results.update(host_facts())
    for name in opts.sessions.split(","):
        Session(name).run()
    summary = {}
    for r in results["runs"]:
        script = r.get("script") or {}
        summary[f"{r['session']}.{r['phase']}"] = {
            "invalid": r.get("invalid") or None,
            "key_p95_ms": (r.get("key_to_frame_ms") or {}).get("p95"),
            "missed_frames": (r.get("frames") or {}).get("missed") if isinstance(r.get("frames"), dict) else None,
            "stalls": (r.get("hangs") or {}).get("count") if isinstance(r.get("hangs"), dict) else None,
            "script_applied_per_s": {k: v.get("applied_per_s") for k, v in script.items() if isinstance(v, dict)} or None,
            "script_refused": {k: v.get("refused") for k, v in script.items() if isinstance(v, dict)} or None,
            "stress_shape_missed": r.get("stress_shape_missed")}
    results["summary"] = summary
    note(f"SCRIPT-STORM key column {KEY_COLUMN} {json.dumps(summary)} displays {results.get('displays')}")
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)


if __name__ == "__main__":
    main()
