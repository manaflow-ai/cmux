#!/usr/bin/env python3
"""The person's input and frames while a script storms cmux (Lawrence 2026-10-24: "people will script cmux a lot more
than chrome ... imagine a bunch of scripted sidebar reorders or pane movement, new columns ... esp in backgrounded
workspaces, we want it from first principles not to block anything at all").

Launches the tagged app (bench_launch.py: no activation, scratch config, isolated Chief, the typing probe, the hang
watchdog at 8 ms), builds the session (light: --background workspaces of one terminal; stress: see SESSION SHAPE), and
gives each of --background background workspaces two panes and a spare tab. Then, per phase, the person types
--samples keys into a terminal of the shown workspace, one key in flight (each key is sent only after the probe wrote
the previous key's row, at most --interval apart; `debug.key` stamped right before the send on an open control
connection, so the wait for the main thread counts), and presses Cmd-D / Cmd-W --splits times (each split checked: a
new focused pane in the measured workspace, closed again, the typed tab still there), while:

  idle     nothing else runs
  script   a script process (this file with --storm-worker, so the person's keys come from a process with no busy
           threads) drives cmux, open loop, at --rates ops per second, each kind on its own connection (each answered
           one ping before any kind is paced):
             reorder     move-workspace of a random background workspace to a random index (daemon)
             move        move-tab of the spare tab between the two panes of a background workspace (daemon)
             column      one op per step in the next background workspace: new-pane-right / new-row (in turn, by
                         create) while that workspace has fewer than --live-columns script panes, the storm fewer than
                         --max-live-terminals and the host's PTYs in use stay under MAX_PTY_LIMIT, else close-tabs
                         (end_terminals) of the oldest live one; closed from the create's reply, every one closed again
                         when the phase ends (daemon)
             rename      rename-surface of a background tab (daemon)
             app-rename  action.run renameTab (wait: false) of a background tab: the app-side load (control socket).
                         Each run emits the always-on action.perform/action.commit signposts, so this load also adds
                         about 4 log events per op to the `log stream` the split rows come from.
             batch       one action.batch (wait: false) of BATCH_OPS renameTab ops on background tabs per step: the
                         app-side transaction (control socket); the rate is batches per second (default 10: 640 ops/s)

Per session and phase:
  key_to_contents_ms   the probe's contents_ms (see KEY_COLUMN): NOT a committed frame and not comparable with the
                       10 ms key-to-committed-frame target. The frame evidence next to it is debug.frames (missed
                       vsyncs over 1.5 periods, main-thread busy per frame).
  split input-to-commit `action.input_to_commit` signposts (perf-signposts.py), invalid on its own when `log stream`
                       lost messages or a press has no interval.
  display frames (debug.frames), main-thread stalls over 8 ms (debug.hangs), the control work queue (debug.queue), and
  per op kind the asked rate, the applied rate (ok replies per second) over the person's key and split window and in
  its slowest second, refusals and reply latency.
A phase is reported "invalid" with its reasons and no key numbers when: its storm was not applied during the person's
window (an applied rate, overall or in any second of the window, under MIN_APPLIED_SHARE of the asked one, refusals
over MAX_REFUSED_SHARE); any key was censored (no probe row within KEY_DEADLINE_S: its wait is reported as a lower
bound); focus or the shown workspace left the typed tab; the typed letters are not on the typed tab's screen; or its
splits failed their check. The report states host, macOS and display refresh. No gate: a measurement (perf cron runs it
opportunistically).

SESSION SHAPE: the typing probe is not bound to a surface (any terminal's output closes a key's sample), so no
terminal the person cannot see may print while they type. The "stress" session is therefore STRESS with its 10 busy
terminals in never-shown background workspaces (perf-stress-session.py busy_where=elsewhere) plus the two terminals and
spare tab of the background setup: lighter than the shared STRESS, labeled "STRESS-busy-elsewhere" in the report, and
not comparable with other STRESS benches' numbers. Move the busy terminals back (busy_where=measured) once the probe is
surface-bound.

Terminals are a shared host resource (kern.tty.ptmx_max 511, shared by every agent): the build, the setup and every
script phase refuse to start when the PTYs in use plus the ones they open would reach bench_cli_storm's MAX_PTY_LIMIT,
and the column load checks the PTYs in use before each create.

  script-storm-bench.py --app APP --out DIR [--sessions light,stress] [--seconds 15] [--samples 120]
      [--rates reorder=1000,move=200,column=100,rename=500,app-rename=640,batch=10] [--background 50] [--json FILE]

The STRESS session is built by perf-stress-session.py, which checks its shape: a session of another shape reports
"STRESS shape missed" and no numbers. The app launches through bench_launch.py.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=script-storm [--arg=--vdisplay=120] [--arg=--sessions=light]
"""
import argparse, collections, importlib.util, json, os, random, select, signal, socket, statistics, subprocess, sys
import threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from bench_cli_storm import MAX_PTY_LIMIT, daemon_socket, ptys_in_use  # noqa: E402

# Validity of a phase. A storm that applied less than 90% of an asked rate (over the person's window, or in any one
# second of it), or had more than 1% of its ops refused, is not the asked load.
MIN_APPLIED_SHARE = 0.9
MAX_REFUSED_SHARE = 0.01
# A split that has not made (or closed) its pane after 5 s, 500 times the 10 ms target, failed.
SPLIT_DEADLINE_S = 5.0
# A key whose probe row has not closed 1 s after its send (100 times the 10 ms target) is censored: the phase is
# invalid and that wait is reported as the key's lower bound. The next key is not sent before then.
KEY_DEADLINE_S = 1.0
# Bounded waits for the script process: its connections' first replies, and the end-of-phase closes.
STORM_START_DEADLINE_S = 20.0
STORM_DRAIN_DEADLINE_S = 30.0
# perf-signposts.py stops `log stream` (up to 10 s) and joins its reader (up to 10 s) after SIGINT.
SIGNPOSTS_STOP_DEADLINE_S = 30.0
# The probe column reported as key_to_contents_ms: the first `setContents:` on a terminal IOSurfaceLayer after the
# echo's parse (TypingFrameProbe). It is not bound to the typed surface and is set before Core Animation commits that
# run-loop turn: work later in the same turn (the storm's snapshot and sidebar work) is not in it, so it is not a
# committed frame and is never compared with the 10 ms target. A surface-bound mark at the CA commit after contents
# needs the probe change (TypingLatencyProbe); debug.frames' missed vsyncs and main-thread busy are the frame evidence.
KEY_COLUMN = "contents_ms"
SESSION_SHAPE = {"light": "light", "stress": "STRESS-busy-elsewhere"}


def uptime():
    """Seconds since boot (CLOCK_UPTIME_RAW): one clock for this process, the script process and the app's probe."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


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


PING = {daemon_frame: "ping", control_frame: "system.ping"}


class Connection:
    """A pipelined JSON-lines connection (the session daemon's `{"id", "cmd", ...}` or the app's control
    `{"id", "method", "params"}`): `send` never waits for a reply; a reader thread matches replies by id, counts ok
    replies (with their uptime) and refusals, records latency, keeps a reply only when `send` asked for it, and calls
    `on_reply(message, context, ok)` for every reply that has a context. At most `max_inflight` requests wait
    unanswered; past that `send` returns None (the script is faster than cmux: counted, not queued)."""

    def __init__(self, path, frame, max_inflight, on_reply=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.frame, self.max_inflight, self.on_reply = frame, max_inflight, on_reply
        self.cond = threading.Condition()
        self.write_lock = threading.Lock()
        self.pending, self.kept, self.next_id = {}, {}, 1
        self.closed = False
        self.reset()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def reset(self):
        with self.cond:
            self.latencies, self.refusals, self.ok_times = [], {}, []
            self.sent = self.ok = self.skipped = self.send_failed = self.replied = 0

    def warm(self, timeout):
        """One ping answered ok within `timeout` (the connection is up and served); the counts then start from zero,
        so the ping is not a storm op. Whether it answered."""
        reply = self.wait_reply(self.send(PING[self.frame], {}, keep=True), timeout)
        self.reset()
        return (reply or {}).get("ok") is True

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
                        self.ok_times.append(uptime())
                    else:
                        code = error_code(message)
                        self.refusals[code] = self.refusals.get(code, 0) + 1
                # Outside the condition (on_reply takes its owner's lock, which a step holds while it sends), and
                # before the request leaves `pending`: a waiter that sees it answered also sees what on_reply did.
                if self.on_reply and context is not None:
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

    def report(self, seconds, asked, window=None):
        with self.cond:
            refused = sum(self.refusals.values())
            return {"asked_per_s": asked, "sent": self.sent, "ok": self.ok,
                    "applied_per_s": round(self.ok / seconds, 1) if seconds else None,
                    "window": applied_in(self.ok_times, window),
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


def applied_in(ok_times, window):
    """The ok replies inside `window` ([start, end] uptime seconds, the person's keys and splits): the rate over it
    and per whole second of it (a part second at the end is left out unless the window is shorter than one), so a
    storm that stalls while the person types and catches up later shows its slow second."""
    if not window or window[1] <= window[0]:
        return None
    start, end = window
    inside = [t for t in ok_times if start <= t <= end]
    length = end - start
    whole = int(length)
    if whole:
        seconds = [0] * whole
        for t in inside:
            if t < start + whole:
                seconds[int(t - start)] += 1
    else:
        seconds = [round(len(inside) / length, 1)]
    return {"seconds": round(length, 2), "ok": len(inside), "applied_per_s": round(len(inside) / length, 1),
            "slowest_second_per_s": min(seconds), "per_second": seconds}


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

    def report(self, seconds, window):
        report = self.connection.report(seconds, self.rate, window)
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


# One action.batch transaction: ControlRouter.batchOpLimit, the most one transaction takes.
BATCH_OPS = 64


def batch_load(plan, rng):
    connection = Connection(plan["control"], control_frame, plan["max_inflight"])
    ids = [t for ws in plan["background"] for t in ws["tab_ids"]]
    return Load("batch", plan["rates"]["batch"], connection, lambda i: connection.send(
        "action.batch", {"ops": [{"action": "renameTab", "target": f"tab:{rng.choice(ids)}", "args": {"name": f"batch {i}.{k}"},
                                  "focus": False} for k in range(BATCH_OPS)],
                         "wait": False, "origin": "script"}))


class ColumnLoad(Load):
    """New panes in background workspaces, each closed again from its create's reply. A terminal counts as live from
    its create's send until its close's ok reply, so the live terminals never pass --live-columns per workspace or
    --max-live-terminals for the storm. A closed terminal frees its PTY only when its terminal host exits, after the
    close's reply: each create first checks the host's PTYs in use, and closes instead when one more would reach
    MAX_PTY_LIMIT."""

    def __init__(self, plan, rng):
        self.background = plan["background"]
        self.per_workspace, self.cap = plan["live_columns"], plan["max_live_terminals"]
        self.lock = threading.Lock()
        self.alive = {ws["handle"]: 0 for ws in self.background}  # creating + live + closing, per workspace
        self.live = collections.OrderedDict()  # surface -> workspace handle, oldest first
        self.total = 0
        self.held = self.held_pty = self.creates_ok = self.closes_ok = self.creates_sent = 0
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

    def under_limits(self, handle):
        return self.alive[handle] < self.per_workspace and self.total < self.cap

    def step(self, i):
        ws = self.background[i % len(self.background)]
        handle = ws["handle"]
        with self.lock:
            wants = self.under_limits(handle)
        # Read outside the lock (a /dev listing): only this thread adds terminals, so the answer stays conservative.
        pty_room = wants and ptys_in_use() + 1 < MAX_PTY_LIMIT
        with self.lock:
            if pty_room and self.under_limits(handle):
                # In turn by create, not by step: at a limit the steps alternate create and close, so a step parity
                # would make nearly every create the same op.
                op, surface = ("new-row" if self.creates_sent % 2 else "new-pane-right"), None
                self.creates_sent += 1
                self.alive[handle] += 1
                self.total += 1
            else:
                if wants and not pty_room:
                    self.held_pty += 1
                # At a limit: close this workspace's oldest pane, or the storm's oldest when only the storm (or the
                # host's PTYs) is full.
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
        """Every pane this storm made, closed again: the creates still in flight answered first, then one close each.
        The terminal ledger (creates_ok, closes_ok) is read after these closes; the paced counts (sent, ok, applied)
        are read before them, so closes_at_end is the only part of the ledger the pacing did not send."""
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
            return {"creates_answered": bool(answered), "closes_answered": bool(drained), "closes_at_end": len(surfaces),
                    "creates_ok": self.creates_ok, "closes_ok": self.closes_ok,
                    "terminals_left_open": self.total, "unclosable": self.unclosable[:20]}

    def report(self, seconds, window):
        report = super().report(seconds, window)
        with self.lock:
            report.update({"held_at_limit": self.held, "creates_held_at_pty_limit": self.held_pty})
        return report


LOADS = {"reorder": reorder_load, "move": move_load, "column": ColumnLoad, "rename": rename_load,
         "app-rename": app_rename_load, "batch": batch_load}


def storm_worker(plan_path):
    """The script: once every kind's connection has answered a ping, paces every kind until a line (or EOF) on stdin,
    then closes what it made and prints its report as one JSON line on stdout. The stop line is JSON `{"window":
    [start, end]}` (uptime seconds of the person's keys and splits): each kind's applied rate is also reported over
    that window. Nothing is paced (so nothing is made) when a connection does not answer."""
    with open(plan_path) as handle:
        plan = json.load(handle)
    loads = []
    try:
        for index, (kind, rate) in enumerate(sorted(plan["rates"].items())):
            if rate:
                loads.append(LOADS[kind](plan, random.Random(7 + index)))
        silent = [load.kind for load in loads if not load.connection.warm(STORM_START_DEADLINE_S)]
    except OSError as error:
        print(json.dumps({"running": False, "error": repr(error)[:300]}), flush=True)
        for load in loads:
            load.connection.close()
        return 1
    if silent:
        print(json.dumps({"running": False, "unanswered_ping": silent}), flush=True)
        for load in loads:
            load.connection.close()
        return 1
    started = time.perf_counter()
    for load in loads:
        load.thread.start()
    print(json.dumps({"running": True, "kinds": [load.kind for load in loads]}), flush=True)
    line = sys.stdin.readline()
    seconds = time.perf_counter() - started
    for load in loads:
        load.thread.stop()
    try:
        window = json.loads(line).get("window") if line.strip() else None
    except (ValueError, AttributeError):
        window = None
    report = {"seconds": round(seconds, 2), "window": window}
    for load in loads:
        paced = load.report(seconds, window)  # before finish(): its closes are not paced ops
        report[load.kind] = {**paced, **load.finish()}
        load.connection.close()
    print(json.dumps(report), flush=True)
    return 0


if __name__ == "__main__" and sys.argv[1:2] == ["--storm-worker"]:
    sys.exit(storm_worker(sys.argv[2]))


# The bench.

from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag")  # split-spring.sh passes it; the tag comes from the bundle
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--sessions", default="light,stress")
parser.add_argument("--phases", default="idle,script")
parser.add_argument("--seconds", type=float, default=15.0, help="length of each phase's script load")
parser.add_argument("--samples", type=int, default=120)
parser.add_argument("--interval", type=float, default=0.1,
                    help="the person's pace: at least this many seconds between key sends (each also waits for the last key's row)")
parser.add_argument("--splits", type=int, default=10, help="Cmd-D then Cmd-W pairs per phase")
parser.add_argument("--rates", default="reorder=1000,move=200,column=100,rename=500,app-rename=640,batch=10")
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
results = {"host": os.uname().nodename, "opts": vars(opts), "key_column": KEY_COLUMN, "session_shapes": SESSION_SHAPE,
           "log": [], "runs": []}


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


class ProbeRows:
    """The typing probe's CSV (TypingLatencyProbe) read as the app appends it: rows by sample index. A row is written
    when its sample closes (complete at the frame's contents, or cut off by the next key-down), so a wait for a row
    waits on the file's kqueue write events, the probe's own signal, never on a timer. Opened after the session is
    built: the app creates the file when its first terminal view comes up."""

    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY)
        self.kq = select.kqueue()
        self.kq.control([select.kevent(self.fd, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                       fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0, 0)
        self.header, self.partial, self.rows, self.last = None, b"", {}, -1

    def read(self):
        while True:
            chunk = os.read(self.fd, 1 << 16)
            if not chunk:
                break
            self.partial += chunk
        *lines, self.partial = self.partial.split(b"\n")
        for line in lines:
            values = line.decode(errors="replace").split(",")
            if self.header is None:
                self.header = values
                continue
            row = dict(zip(self.header, values))
            if row.get("index", "").isdigit():
                index = int(row["index"])
                self.rows[index] = row
                self.last = max(self.last, index)

    def wait(self, predicate, deadline):
        """`predicate()` once it is not None, re-read on each write to the file; None at `deadline` (monotonic)."""
        while True:
            self.read()
            found = predicate()
            if found is not None:
                return found
            rest = deadline - time.monotonic()
            if rest <= 0:
                return None
            self.kq.control(None, 1, rest)

    def close(self):
        self.kq.close()
        os.close(self.fd)


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
        self.measured = self.typed_pane = self.typed_tab = self.typed_surface = None
        self.probe = None  # ProbeRows, opened at the first phase
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
        b = self.builder
        # One terminal per workspace, and two in each measured pane (the grid plus one nested split per nested column).
        terminals = (b.WORKSPACES + 2 * (b.COLUMNS * b.ROWS + len(b.NESTED_COLUMNS)) if self.name == "stress"
                     else opts.background + 2)
        pty_guard(f"the {self.name} build", terminals)
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
        self.typed_surface = tab.get("surface")
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
        try:
            line = worker.stdout.readline()
            start = json.loads(line) if line.strip() else {}
        except ValueError:
            start = {}
        if not start.get("running"):
            # The worker paces nothing before every ping answered, so it made nothing; it exits on its own.
            self.abort_storm(worker)
            raise RuntimeError(f"the script process did not start (first line {line.strip()[:200]!r}; see its log)")
        return worker

    @staticmethod
    def stop_storm(worker, window):
        out, _ = worker.communicate(json.dumps({"window": window}) + "\n", timeout=STORM_DRAIN_DEADLINE_S * 2 + 60)
        lines = out.strip().splitlines()
        return json.loads(lines[-1]) if lines else {"error": f"the script process exited {worker.returncode} with no report"}

    @staticmethod
    def abort_storm(worker):
        """A phase that failed: the stop line, so the worker closes every terminal it made (finish()), then its exit;
        killed only when it does not exit within its own drain deadlines."""
        deadline = STORM_DRAIN_DEADLINE_S * 2 + 60
        try:
            try:
                worker.communicate("{}\n", timeout=deadline)
            except ValueError:  # stop_storm already sent its stop line and timed out waiting for the report
                worker.communicate(timeout=deadline)
        except subprocess.TimeoutExpired:
            worker.kill()
            worker.communicate()

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
            window = report.get("window")
            if not window:
                problems.append(f"{kind}: no applied rate over the person's window")
                continue
            applied, slowest = window.get("applied_per_s") or 0, window.get("slowest_second_per_s") or 0
            if applied < MIN_APPLIED_SHARE * rate:
                problems.append(f"{kind}: applied {applied}/s of {rate:g}/s asked while the person typed and split")
            elif slowest < MIN_APPLIED_SHARE * rate:
                problems.append(f"{kind}: applied {slowest}/s of {rate:g}/s asked in the slowest second of the person's window")
            if report.get("refused", 0) > MAX_REFUSED_SHARE * max(report.get("sent", 0), 1):
                problems.append(f"{kind}: {report.get('refused')} of {report.get('sent')} refused {report.get('refusals')}")
            if report.get("terminals_left_open"):
                problems.append(f"{kind}: {report['terminals_left_open']} script terminals left open")
        return problems

    # The person.

    def focus(self):
        return self.topology().get("focus") or {}

    def measured_panes(self):
        return self.stress.panes(self.stress.workspace(self.measured))

    def typed_tab_present(self):
        return any(t.get("id") == self.typed_tab for p in self.measured_panes() for t in p.get("tabs") or [])

    def focus_problems(self, when, typed=True):
        """Where the person's keys go: the measured workspace shown and focused, and (typed) the typed pane and tab. The
        probe is not bound to the typed surface, so keys that went elsewhere would still close rows."""
        topology = self.topology()
        focus = topology.get("focus") or {}
        shown = {w.get("workspace") for w in topology.get("windows") or []}
        problems = []
        if self.measured not in shown:
            problems.append(f"{when}: the measured workspace {self.measured} is no longer shown (shown {sorted(map(str, shown))})")
        if focus.get("workspace") != self.measured:
            problems.append(f"{when}: focus moved to workspace {focus.get('workspace')}")
        elif typed and (focus.get("pane"), focus.get("tab")) != (self.typed_pane, self.typed_tab):
            problems.append(f"{when}: focus moved to pane {focus.get('pane')} tab {focus.get('tab')} "
                            f"(typed pane {self.typed_pane} tab {self.typed_tab})")
        return problems

    def screen_problem(self, typed):
        """The typed letters on the typed tab's screen (daemon read-screen; soft wraps joined), or why not."""
        if self.typed_surface is None:
            return "the typed tab has no daemon surface in the snapshot: the typed letters could not be checked"
        connection = Connection(self.daemon_path, daemon_frame, 4)
        try:
            reply = connection.wait_reply(connection.send("read-screen", {"surface": int(self.typed_surface)}, keep=True), 15)
        finally:
            connection.close()
        if (reply or {}).get("ok") is not True:
            return f"read-screen of the typed tab refused: {error_code(reply or {'error': 'no reply'})}"
        text = "".join(((reply.get("data") or {}).get("text") or "").split())
        if typed not in text:
            return f"the {len(typed)} typed letters are not on the typed tab's screen (its end: {text[-120:]!r})"
        return None

    def press_sample(self, keys, key, modifiers=None):
        """Presses `key` and waits for its probe row: (the complete row or None, seconds waited, debug.key reply). The
        key's sample is the next one the probe opens: one past the last row written, or one further when that row comes
        back cut off (an earlier key-down's sample, closed by this key-down). Only this process sends keys, and the next
        key waits for this row, so no later key-down can cut this key's sample off: no row by KEY_DEADLINE_S means
        no frame yet (censored)."""
        probe = self.probe
        probe.read()
        expected = [probe.last + 1]

        def own_row():
            while True:
                row = probe.rows.get(expected[0])
                if row is None or row.get("complete") == "1":
                    return row
                expected[0] += 1
        pressed = time.monotonic()
        reply = keys.press(key, modifiers)
        row = probe.wait(own_row, pressed + KEY_DEADLINE_S)
        return row, time.monotonic() - pressed, reply

    def type_keys(self, keys):
        """--samples keys, one in flight: (key_to_contents ms of the closed ones, censored waits in ms, problems)."""
        letters = "abcdefghijklmnopqrstuvwxyz"
        problems, closed, censored, refused = [], [], [], []
        # Not a sample: it closes a sample an earlier key-down (Cmd-W, the last phase's Ctrl-U) may have left open.
        self.press_sample(keys, "z")
        typed = "z"
        for index in range(opts.samples):
            letter = letters[index % len(letters)]
            started = time.monotonic()
            row, waited, reply = self.press_sample(keys, letter)
            typed += letter
            if isinstance(reply, dict) and reply.get("error"):
                refused.append(str(reply["error"])[:120])
            if row is not None and row.get(KEY_COLUMN):
                closed.append(float(row[KEY_COLUMN]))
            else:
                censored.append(round(waited * 1000, 1))
            rest = opts.interval - (time.monotonic() - started)
            if rest > 0:
                time.sleep(rest)  # the person's typing pace: a delay by design, never a wait for a condition
        if censored:
            problems.append(f"{len(censored)} of {opts.samples} keys censored (no frame within {KEY_DEADLINE_S:g} s; "
                            f"lower bounds {censored[:12]} ms)")
        if refused:
            problems.append(f"debug.key refused {len(refused)} keys, first {refused[0]!r}")
        problem = self.screen_problem(typed)
        if problem:
            problems.append(problem)
        problems += self.focus_problems("after the keys")
        # Clears the typed line; its row is waited for (so no sample stays open) but is not a sample.
        self.press_sample(keys, "u", ["ctrl"])
        return closed, censored, problems

    def splits(self, keys):
        """Cmd-D then Cmd-W, each checked: (problems, keys pressed). The first failure ends the pairs."""
        presses = 0
        for index in range(opts.splits):
            before = {p.get("id") for p in self.measured_panes()}

            def new_focused_pane():
                focus = self.focus()
                if focus.get("workspace") == self.measured and focus.get("pane") not in before:
                    return focus.get("pane")
                return None
            keys.press("d", ["cmd"])
            presses += 1
            made = self.builder.wait(new_focused_pane, SPLIT_DEADLINE_S, step=0.02)
            if not made:
                return [f"split {index + 1}: Cmd-D focused no new pane of the measured workspace in {SPLIT_DEADLINE_S:g} s"], presses
            time.sleep(0.4)  # bench script: the person looks at the new pane
            keys.press("w", ["cmd"])
            presses += 1
            if not self.builder.wait(lambda: made not in {p.get("id") for p in self.measured_panes()}, SPLIT_DEADLINE_S, step=0.02):
                return [f"split {index + 1}: Cmd-W did not close the new pane {made} in {SPLIT_DEADLINE_S:g} s"], presses
            if not self.typed_tab_present():
                return [f"split {index + 1}: the typed tab {self.typed_tab} is gone after Cmd-W"], presses
            time.sleep(0.4)  # bench script: and goes on
        return self.focus_problems("after the splits", typed=False), presses

    # The split signposts.

    def start_signposts(self, phase):
        """perf-signposts.py on the app's `action` signposts until stop_signposts sends it SIGINT."""
        pid = (self.app.running_pids() or [None])[0]
        if not pid:
            return None
        save = os.path.join(OUT, self.name, f"signposts-{phase}.ndjson")
        log = open(os.path.join(OUT, self.name, f"signposts-{phase}.log"), "w")
        process = subprocess.Popen([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(pid),
                                    "--category", "action", "--allow-loss", "--require-input-age", "--save", save, "--json"],
                                   stdout=subprocess.PIPE, stderr=log, text=True)
        log.close()
        time.sleep(1)  # bench script: `log stream` attaches before the first key
        return process

    @staticmethod
    def stop_signposts(process):
        """SIGINT (perf-signposts stops `log stream` and prints its JSON), then its report with its exit status."""
        process.send_signal(signal.SIGINT)
        try:
            out, _ = process.communicate(timeout=SIGNPOSTS_STOP_DEADLINE_S)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            return {"error": f"perf-signposts did not stop within {SIGNPOSTS_STOP_DEADLINE_S:g} s"}
        try:
            report = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
        except ValueError:
            return {"error": "unparsed", "out": out[-2000:]}
        return {**report, "status": process.returncode}

    @staticmethod
    def abort_signposts(process):
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
        try:
            process.communicate(timeout=SIGNPOSTS_STOP_DEADLINE_S)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()

    @staticmethod
    def split_commits(report, presses):
        """The person's action.input_to_commit rows, or why they do not describe every press: (rows, problems)."""
        if report is None:
            return None, ["no signpost stream (the app's pid was not found)"]
        if report.get("error"):
            return None, [f"signposts: {report['error']}"]
        rows = report.get("rows") or []
        problems = []
        if report.get("lost"):
            problems.append(f"log stream lost messages {report['lost']} time(s) (the app-rename and batch loads add about 4 "
                            "action signposts per op): the person's intervals may be missing")
        if report.get("status") == 3:
            problems.append("user action runs carry no input age: input to commit is empty")
        person = [r for r in rows if r.get("name") == "action.input_to_commit" and r.get("detail") != "*"]
        ids = {r.get("detail") for r in person}
        # A run whose commit the boundary missed has no input-to-commit row; it is still the person's press.
        missed = sum(r.get("count", 0) for r in rows if r.get("name") == "action.commit.missed" and r.get("detail") in ids)
        intervals = sum(r.get("count", 0) for r in person) + missed
        if presses and intervals < presses:
            problems.append(f"{intervals} input-to-commit intervals for {presses} Cmd-D/Cmd-W presses "
                            f"({report.get('unpaired')} unpaired begins in the stream)")
        return (None if problems else person), problems

    def measure(self, phase):
        self.action("pane.focus", target=f"pane:{self.typed_pane}")
        self.action("tab.focus", target=f"tab:{self.typed_tab}")
        invalid = []
        if not self.builder.wait(lambda: self.focus().get("pane") == self.typed_pane, 10, step=0.05) or not self.typed_tab_present():
            invalid.append(f"focus never reached the typed pane {self.typed_pane} with its tab {self.typed_tab}")
        if self.probe is None:
            self.probe = ProbeRows(PROBE)
        worker = signposts = keys = None
        try:
            signposts = self.start_signposts(phase)
            worker = self.start_storm(phase) if phase == "script" else None
            self.rpc("debug.hangs", {"clear": True})
            self.rpc("debug.queue", {"reset": True})
            self.rpc("debug.frames", {"action": "start"})
            started = time.perf_counter()
            window_start = uptime()
            keys = Keys(self.app.socket)
            closed, censored, key_problems = self.type_keys(keys)
            split_problems, presses = self.splits(keys)
            window = [window_start, uptime()]
            keys.close()
            keys = None
            signpost_report = self.stop_signposts(signposts) if signposts else None
            signposts = None
            if worker:
                rest = opts.seconds - (time.perf_counter() - started)
                if rest > 0:
                    time.sleep(rest)  # bench script: the storm runs its full length
            elapsed = time.perf_counter() - started
            frames = self.rpc("debug.frames", {"action": "stop"}, timeout=20)
            hangs = self.rpc("debug.hangs", {"limit": 12}, timeout=20)
            queue = self.rpc("debug.queue", timeout=20)
            script = self.stop_storm(worker, window) if worker else None
            worker = None
        finally:
            if keys:
                keys.close()
            if worker:
                self.abort_storm(worker)
            if signposts:
                self.abort_signposts(signposts)
        if script is not None:
            invalid += [f"storm not applied: {p}" for p in self.storm_problems(script)]
        invalid += key_problems
        if split_problems:
            invalid += split_problems
            if not split_problems[0].startswith("after the splits"):
                self.broken = split_problems[0]
        split_rows, split_invalid = self.split_commits(signpost_report, presses)
        f = frames if isinstance(frames, dict) else {}
        frame_evidence = {k: f.get(k) for k in ("refresh_ms", "frames", "missed", "main_p95_ms", "main_max_ms", "main_over_8_3_ms")}
        entry = {"session": self.name, "shape": SESSION_SHAPE.get(self.name, self.name), "phase": phase,
                 "seconds": round(elapsed, 1), "invalid": invalid,
                 "key_to_contents_ms": None if invalid else pct(closed), "key_column": KEY_COLUMN,
                 "key_to_contents_is_committed_frame": False, "frame_evidence": frame_evidence,
                 "keys": opts.samples, "keys_closed": len(closed), "keys_censored": len(censored),
                 "censored_lower_bounds_ms": censored,
                 "key_to_contents_with_censored_lower_bounds_ms": pct(closed + censored) if censored else None,
                 "split_input_to_commit": None if split_problems else split_rows, "split_presses": presses,
                 "split_input_to_commit_invalid": split_invalid,
                 "signposts": {k: (signpost_report or {}).get(k) for k in ("lost", "unpaired", "status", "error")},
                 "signpost_load": "app-rename and batch add about 4 action signposts per op to the stream the split rows come from"
                 if script is not None and (RATES.get("app-rename") or RATES.get("batch")) else None,
                 "frames": frames,
                 "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms", "records")}
                 if isinstance(hangs, dict) else hangs,
                 "queue": queue, "script": script}
        k = entry["key_to_contents_ms"] or {}
        applied = {kind: ((v.get("window") or {}).get("applied_per_s"), (v.get("window") or {}).get("slowest_second_per_s"),
                          v.get("asked_per_s"), v.get("refused"))
                   for kind, v in (script or {}).items() if isinstance(v, dict) and "asked_per_s" in v}
        note(f"{self.name}.{phase} ({entry['shape']}): "
             + (f"INVALID ({'; '.join(invalid)}); " if invalid else
                f"key to contents ({KEY_COLUMN}, not a committed frame) p50 {k.get('p50')} p95 {k.get('p95')} "
                f"p99 {k.get('p99')} max {k.get('max')} ms (n={k.get('n')} of {opts.samples}); ")
             + f"frames missed {f.get('missed')} of {f.get('frames')} at {f.get('refresh_ms')} ms, main busy p95 "
             f"{f.get('main_p95_ms')} max {f.get('main_max_ms')} ms, over 8.3 ms {f.get('main_over_8_3_ms')}; "
             f"stalls {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}"
             + (f"; split input-to-commit INVALID ({'; '.join(split_invalid)})" if split_invalid else "")
             + (f"; script applied in window/slowest second/asked/refused per kind {json.dumps(applied)}" if script else ""))
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
            missing = [m for m in ("action.run", "action.batch", "snapshot.get", "debug.key", "debug.frames") if m not in methods]
            if missing:
                note(f"{self.name}: the app has no {missing}; nothing measured")
                results["runs"].append({"session": self.name, "phase": "build", "missing_methods": missing})
                return
            try:
                measured = self.build()
            except PtyRefusal as error:
                note(f"{self.name}: not built: {error}; nothing measured")
                results["runs"].append({"session": self.name, "phase": "build", "pty_refusal": str(error)})
                return
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
            if self.probe:
                self.probe.close()
            self.app.stop()


def main():
    results.update(host_facts())
    for name in opts.sessions.split(","):
        Session(name).run()
    summary = {}
    for r in results["runs"]:
        script = r.get("script") or {}
        evidence = r.get("frame_evidence") or {}
        summary[f"{r['session']}.{r['phase']}"] = {
            "shape": r.get("shape") or SESSION_SHAPE.get(r["session"], r["session"]),
            "invalid": r.get("invalid") or None,
            # Not a committed frame (KEY_COLUMN): never read against the 10 ms key-to-frame target.
            "key_to_contents_p95_ms": (r.get("key_to_contents_ms") or {}).get("p95"),
            "keys_censored": r.get("keys_censored"),
            "missed_frames": evidence.get("missed"), "refresh_ms": evidence.get("refresh_ms"),
            "main_busy_p95_ms": evidence.get("main_p95_ms"), "main_busy_max_ms": evidence.get("main_max_ms"),
            "split_input_to_commit_invalid": r.get("split_input_to_commit_invalid") or None,
            "stalls": (r.get("hangs") or {}).get("count") if isinstance(r.get("hangs"), dict) else None,
            "script_applied_in_window_per_s": {k: (v.get("window") or {}).get("applied_per_s")
                                               for k, v in script.items() if isinstance(v, dict) and "asked_per_s" in v} or None,
            "script_slowest_second_per_s": {k: (v.get("window") or {}).get("slowest_second_per_s")
                                            for k, v in script.items() if isinstance(v, dict) and "asked_per_s" in v} or None,
            "script_refused": {k: v.get("refused") for k, v in script.items() if isinstance(v, dict) and "asked_per_s" in v} or None,
            "stress_shape_missed": r.get("stress_shape_missed")}
    results["summary"] = summary
    note(f"SCRIPT-STORM key column {KEY_COLUMN} (key to contents, not a committed frame; frame evidence: missed frames "
         f"and main busy) {json.dumps(summary)} displays {results.get('displays')}")
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)


if __name__ == "__main__":
    main()
