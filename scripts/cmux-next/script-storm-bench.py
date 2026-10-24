#!/usr/bin/env python3
"""The person's input and frames while a script storms cmux (Lawrence 2026-10-24: "people will script cmux a lot more
than chrome ... imagine a bunch of scripted sidebar reorders or pane movement, new columns ... esp in backgrounded
workspaces, we want it from first principles not to block anything at all").

Launches the tagged app (bench_launch.py: no activation, scratch config, isolated Chief, the typing probe, the hang
watchdog at 8 ms), builds the session (light: --background workspaces of one terminal; stress: the STRESS session of
perf-stress-session.py), and gives each of --background background workspaces two panes and a spare tab. Then, per
phase, the person types --samples keys into a terminal of the shown workspace (`debug.key` stamped with the send time,
so the wait for the main thread counts) and presses Cmd-D / Cmd-W --splits times, while:

  idle     nothing else runs
  script   a script drives the session daemon over its socket, open loop, at --rates ops per second:
             reorder  move-workspace of a random background workspace to a random index
             move     move-tab of the spare tab between the two panes of a background workspace
             column   new-pane-right / new-row in a background workspace, each closed again (close-tabs, ending its
                      terminal) once --live-columns are alive there
             rename   rename-surface of a background tab
           plus, every --batch-every seconds, one app `action.batch` of --batch-ops renameTab ops on background tabs
           (the app-side transaction; its main-thread cost per op is reported as batch_apply_us_per_op)

Per session and phase: key to frame p50/p95/p99/max (the probe's contents_ms), split input-to-commit
(`action.input_to_commit` signposts, perf-signposts.py), display frames (debug.frames: refresh, missed vsyncs over 1.5
periods, main-thread busy per frame), main-thread stalls over 8 ms (debug.hangs), the control work queue
(debug.queue), and the script's achieved rate, refusals and daemon reply latency per op kind. The report states host,
macOS and display refresh. No gate: a measurement (perf cron runs it opportunistically).

  script-storm-bench.py --app APP --out DIR [--sessions light,stress] [--seconds 15] [--samples 120]
      [--rates reorder=1000,move=200,column=100,rename=500] [--background 50] [--batch-ops 64] [--json FILE]

The STRESS session is built by perf-stress-session.py, which checks its shape: a session of another shape reports
"STRESS shape missed" and no numbers. The app launches through bench_launch.py.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --artifact artifacts/split-spring/report.json --arg=--suite=script-storm [--arg=--vdisplay=120] [--arg=--sessions=light]
"""
import argparse, csv, importlib.util, json, os, random, socket, statistics, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402
from bench_cli_storm import daemon_socket  # noqa: E402

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
parser.add_argument("--rates", default="reorder=1000,move=200,column=100,rename=500")
parser.add_argument("--background", type=int, default=50, help="background workspaces the script works in")
parser.add_argument("--live-columns", type=int, default=2, help="script-made panes alive per workspace before closing")
parser.add_argument("--batch-ops", type=int, default=64)
parser.add_argument("--batch-every", type=float, default=0.1)
parser.add_argument("--max-inflight", type=int, default=512, help="unanswered daemon requests per op kind")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
PROBE = os.path.join(OUT, "typing.csv")
RATES = {k: float(v) for k, v in (item.split("=") for item in opts.rates.split(",") if item)}
results = {"host": os.uname().nodename, "opts": vars(opts), "log": [], "runs": []}


def note(text):
    print(text, flush=True)
    results["log"].append(text)


def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


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


class Daemon:
    """A pipelined JSON-lines connection to the session daemon (`{"id", "cmd", ...}`): `send` never waits for a
    reply; a reader thread matches replies by id and records each one's latency. At most `max_inflight` requests
    wait unanswered; past that `send` returns False (the script is faster than the daemon: counted, not queued)."""

    def __init__(self, path, kind, max_inflight):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.kind, self.max_inflight = kind, max_inflight
        self.lock = threading.Lock()
        self.pending, self.next_id = {}, 1
        self.latencies, self.refusals, self.sent, self.skipped = [], {}, 0, 0
        self.replies = {}
        self.closed = False
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def send(self, cmd, keep_reply=False, **params):
        with self.lock:
            if len(self.pending) >= self.max_inflight:
                self.skipped += 1
                return None
            rid = self.next_id
            self.next_id += 1
            self.pending[rid] = (time.perf_counter(), keep_reply)
            self.sent += 1
        try:
            self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        except OSError:
            self.closed = True
            return None
        return rid

    def read(self):
        buffer = b""
        while not self.closed:
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
                rid = message.get("id")
                if rid is None:
                    continue  # an event
                with self.lock:
                    started, keep = self.pending.pop(rid, (None, False))
                    if started is None:
                        continue
                    self.latencies.append((time.perf_counter() - started) * 1000)
                    if message.get("ok") is not True:
                        code = str((message.get("error") or {}).get("code") if isinstance(message.get("error"), dict)
                                   else message.get("error"))[:80]
                        self.refusals[code] = self.refusals.get(code, 0) + 1
                    if keep:
                        self.replies[rid] = message

    def take(self, rid, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:  # bounded wait for one kept reply in a bench script
            with self.lock:
                if rid in self.replies:
                    return self.replies.pop(rid)
            time.sleep(0.002)  # bench script: the reply's arrival
        return None

    def report(self, seconds):
        with self.lock:
            return {"sent": self.sent, "per_s": round(self.sent / seconds, 1), "skipped_inflight_full": self.skipped,
                    "unanswered": len(self.pending), "refusals": dict(self.refusals), "reply_ms": pct(self.latencies)}

    def close(self):
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass


class Paced(threading.Thread):
    """Calls `step(i)` at `rate` per second, open loop (behind schedule: it catches up, never sleeps), until stopped."""

    def __init__(self, rate, step):
        super().__init__(daemon=True)
        self.rate, self.step, self.flag, self.calls = rate, step, threading.Event(), 0

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
            except Exception as error:  # one failed op must not end the storm
                note(f"storm step: {error!r}")
            self.calls += 1

    def stop(self):
        self.flag.set()
        self.join(timeout=30)


class Session:
    """One app launch: its session built, its background prepared, every phase measured."""

    def __init__(self, name):
        self.name = name
        self.app = BenchApp(opts.app, out=os.path.join(OUT, name),
                            env={"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"},
                            config={"browser": {"defaultEngine": "chromium"}, "appearance": {"backgroundOpacity": 1}},
                            window=(80, 40, 1600, 1000))
        self.rpc = self.app.rpc
        self.stress = None
        self.typed_pane = None
        self.background = []  # [{"handle", "panes": [pane handles], "spare": surface, "tabs": [surfaces]}]
        self.daemon_path = None

    def action(self, name, args=None, target=None, focus=True, timeout=60):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def topology(self):
        reply = self.rpc("snapshot.get") or {}
        return reply.get("topology") or {}

    def build(self):
        builder = load_module("perf_stress_session", "perf-stress-session.py")
        self.stress = builder.Stress(self.rpc, log=note)
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
        if tab:
            self.stress.action("tab.focus", target=f"tab:{tab['id']}")
            self.action("terminal.sendText", {"text": "exec /bin/zsh -f\r"}, focus=False)
            time.sleep(1)  # bench script: the prompt draws
        self.typed_pane = last["id"]
        return measured

    def prepare_background(self, measured):
        """Two panes and a spare tab in each of --background workspaces that no window shows (daemon commands)."""
        tui = os.path.join(self.app.app, "Contents/Resources/bin/cmux-tui")
        self.daemon_path = daemon_socket(tui, self.app.tag)
        setup = Daemon(self.daemon_path, "setup", 64)
        shown = {w.get("workspace") for w in self.topology().get("windows") or []}
        chosen = [w for w in self.topology().get("workspaces") or [] if w.get("id") not in shown and w.get("id") != measured]
        for workspace in chosen[: opts.background]:
            panes = [p for s in workspace.get("screens") or [] for p in s.get("panes") or []]
            if not panes:
                continue
            first = panes[0]
            if len(panes) < 2:
                setup.take(setup.send("new-pane-right", keep_reply=True, pane=int(first["handle"])), timeout=15)
            setup.take(setup.send("new-tab", keep_reply=True, pane=int(first["handle"])), timeout=15)
        time.sleep(2)  # bench script: the daemon's events reach the app's snapshot
        for workspace in self.topology().get("workspaces") or []:
            if workspace.get("id") not in {w.get("id") for w in chosen[: opts.background]}:
                continue
            panes = [p for s in workspace.get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]
            if len(panes) < 2:
                continue
            tabs = [t for p in panes for t in p.get("tabs") or []]
            spare = next((t for t in (panes[0].get("tabs") or [])[1:]), None)
            if not spare:
                continue
            self.background.append({"handle": int(workspace["handle"]), "panes": [int(p["handle"]) for p in panes[:2]],
                                    "spare": int(spare["surface"]), "where": 0,
                                    "tabs": [int(t["surface"]) for t in tabs], "tab_ids": [t["id"] for t in tabs],
                                    "made": []})
        setup.close()
        note(f"{self.name}: {len(self.background)} background workspaces prepared")

    # The script.

    def storm(self):
        """The script's threads and connections; returns (threads, connections, batch thread)."""
        rng = random.Random(7)
        count = len(self.topology().get("workspaces") or [])
        connections, threads = {}, []
        background = self.background

        def connection(kind):
            connections[kind] = Daemon(self.daemon_path, kind, opts.max_inflight)
            return connections[kind]

        if RATES.get("reorder"):
            daemon = connection("reorder")
            threads.append(Paced(RATES["reorder"], lambda i: daemon.send(
                "move-workspace", workspace=rng.choice(background)["handle"], index=rng.randrange(max(count - 1, 1)))))
        if RATES.get("move"):
            daemon = connection("move")

            def move(i):
                ws = background[i % len(background)]
                ws["where"] ^= 1
                daemon.send("move-tab", surface=ws["spare"], pane=ws["panes"][ws["where"]], index=0)
            threads.append(Paced(RATES["move"], move))
        if RATES.get("column"):
            daemon = connection("column")
            lock = threading.Lock()

            def column(i):
                ws = background[i % len(background)]
                with lock:
                    if len(ws["made"]) >= opts.live_columns:
                        rid = ws["made"].pop(0)
                        reply = daemon.take(rid, timeout=0)
                        surface = ((reply or {}).get("data") or {}).get("surface")
                        if surface is not None:
                            daemon.send("close-tabs", surfaces=[surface], end_terminals=True)
                if i % 2:
                    rid = daemon.send("new-row", keep_reply=True, pane=ws["panes"][0], height_permille=500)
                else:
                    rid = daemon.send("new-pane-right", keep_reply=True, pane=ws["panes"][0])
                if rid is not None:
                    with lock:
                        ws["made"].append(rid)
            threads.append(Paced(RATES["column"], column))
        if RATES.get("rename"):
            daemon = connection("rename")
            threads.append(Paced(RATES["rename"], lambda i: daemon.send(
                "rename-surface", surface=rng.choice(rng.choice(background)["tabs"]), name=f"storm {i}")))
        batches = {"sent": 0, "refused": {}, "reply_ms": []}

        def batch(i):
            ids = [t for ws in background for t in ws["tab_ids"]]
            ops = [{"action": "renameTab", "target": f"tab:{rng.choice(ids)}", "args": {"name": f"batch {i}.{k}"}}
                   for k in range(opts.batch_ops)]
            started = time.perf_counter()
            reply = self.rpc("action.batch", {"ops": ops, "wait": False, "origin": "script"}, timeout=10)
            batches["reply_ms"].append((time.perf_counter() - started) * 1000)
            batches["sent"] += 1
            if isinstance(reply, dict) and reply.get("error"):
                code = str((reply["error"] or {}).get("code") if isinstance(reply["error"], dict) else reply["error"])[:80]
                batches["refused"][code] = batches["refused"].get(code, 0) + 1
        batch_thread = Paced(1 / opts.batch_every, batch) if opts.batch_ops and opts.batch_every > 0 else None
        return threads, connections, batch_thread, batches

    def batch_cost(self):
        """Main-thread µs per op of one `action.batch` of renameTab on background tabs, by batch length: the work
        queue's total work for exactly one batch (debug.queue), the cap's measured basis."""
        ids = [t for ws in self.background for t in ws["tab_ids"]]
        cost = {}
        for size in (8, 32, 64):
            samples = []
            for attempt in range(5):
                self.rpc("debug.queue", {"reset": True})
                ops = [{"action": "renameTab", "target": f"tab:{ids[(attempt * size + k) % len(ids)]}",
                        "args": {"name": f"cost {size}.{attempt}.{k}"}} for k in range(size)]
                reply = self.rpc("action.batch", {"ops": ops, "origin": "script"}, timeout=30)
                queue = self.rpc("debug.queue") or {}
                if isinstance(reply, dict) and reply.get("error"):
                    cost[str(size)] = {"error": reply["error"]}
                    break
                samples.append(1000 * float(queue.get("total_work_ms") or 0) / size)
            if samples:
                cost[str(size)] = pct(samples)
        return cost

    # The person.

    def probe_rows(self):
        try:
            with open(PROBE) as handle:
                return list(csv.DictReader(handle))
        except OSError:
            return []

    def type_keys(self):
        keys = "abcdefghijklmnopqrstuvwxyz"
        before = len(self.probe_rows())
        for index in range(opts.samples):
            started = time.perf_counter()
            self.rpc("debug.key", {"key": keys[index % len(keys)], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)},
                     timeout=10)
            rest = opts.interval - (time.perf_counter() - started)
            if rest > 0:
                time.sleep(rest)  # bench script: one key in flight
        time.sleep(0.5)  # bench script: the last echo's frame lands
        self.rpc("debug.key", {"key": "u", "modifiers": ["ctrl"]})  # clears the typed line
        rows = [r for r in self.probe_rows()[before:] if r.get("complete") == "1" and r.get("contents_ms")]
        return [float(r["contents_ms"]) for r in rows]

    def splits(self):
        for _ in range(opts.splits):
            self.rpc("debug.key", {"key": "d", "modifiers": ["cmd"], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)})
            time.sleep(0.4)  # bench script: the person looks at the new pane
            self.rpc("debug.key", {"key": "w", "modifiers": ["cmd"], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)})
            time.sleep(0.4)  # bench script: and closes it again

    def measure(self, phase):
        self.action("pane.focus", target=f"pane:{self.typed_pane}")
        pid = (self.app.running_pids() or [None])[0]
        signposts = None
        save = os.path.join(OUT, self.name, f"signposts-{phase}.ndjson")
        if pid:
            signposts = subprocess.Popen([sys.executable, os.path.join(HERE, "perf-signposts.py"), "--pid", str(pid),
                                          "--category", "action", "--allow-loss", "--save", save, "--json",
                                          "--seconds", str(int(opts.seconds + opts.samples * opts.interval + opts.splits + 10))],
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            time.sleep(1)  # bench script: `log stream` attaches before the first key
        storm = None
        if phase == "script":
            threads, connections, batch_thread, batches = self.storm()
            storm = (threads + ([batch_thread] if batch_thread else []), connections, batches)
            for thread in storm[0]:
                thread.start()
            time.sleep(1)  # bench script: the storm is running before the first key
        self.rpc("debug.hangs", {"clear": True})
        self.rpc("debug.queue", {"reset": True})
        self.rpc("debug.frames", {"action": "start"})
        started = time.perf_counter()
        keys = self.type_keys()
        self.splits()
        while phase == "script" and time.perf_counter() - started < opts.seconds:
            time.sleep(0.1)  # bench script: the storm runs its full length
        elapsed = time.perf_counter() - started
        frames = self.rpc("debug.frames", {"action": "stop"}, timeout=20)
        hangs = self.rpc("debug.hangs", {"limit": 12}, timeout=20)
        queue = self.rpc("debug.queue", timeout=20)
        script = None
        if storm:
            for thread in storm[0]:
                thread.stop()
            script = {kind: daemon.report(elapsed) for kind, daemon in storm[1].items()}
            script["batch"] = {"sent": storm[2]["sent"], "refused": storm[2]["refused"], "reply_ms": pct(storm[2]["reply_ms"])}
            for daemon in storm[1].values():
                daemon.close()
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
        entry = {"session": self.name, "phase": phase, "seconds": round(elapsed, 1),
                 "key_to_frame_ms": pct(keys), "keys": opts.samples,
                 "split_input_to_commit": split_rows, "frames": frames,
                 "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms", "records")}
                 if isinstance(hangs, dict) else hangs,
                 "queue": queue, "script": script}
        k = entry["key_to_frame_ms"] or {}
        f = frames if isinstance(frames, dict) else {}
        note(f"{self.name}.{phase}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} p99 {k.get('p99')} max {k.get('max')} ms "
             f"(n={k.get('n')}); frames missed {f.get('missed')} of {f.get('frames')} at {f.get('refresh_ms')} ms; "
             f"stalls {(entry['hangs'] or {}).get('count') if isinstance(entry['hangs'], dict) else '?'}"
             + (f"; script {json.dumps({kind: v.get('per_s') for kind, v in script.items() if isinstance(v, dict) and 'per_s' in v})}" if script else ""))
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
            try:
                measured = self.build()
            except Exception as error:  # the builder's StressShapeError (and any refusal while building)
                if type(error).__name__ != "StressShapeError":
                    raise
                # Another shape is never measured as STRESS.
                note(f"{self.name}: STRESS shape missed: {error}")
                results["runs"].append({"session": self.name, "phase": "build", "stress_shape_missed": str(error)[:2000]})
                return
            self.prepare_background(measured)
            if not self.background:
                note(f"{self.name}: no background workspace could be prepared; nothing measured")
                return
            results.setdefault("batch_apply_us_per_op", {})[self.name] = self.batch_cost()
            note(f"{self.name}: batch apply us/op {json.dumps(results['batch_apply_us_per_op'][self.name])}")
            for phase in opts.phases.split(","):
                try:
                    self.measure(phase)
                except Exception as error:  # one phase failing must not hide the others
                    note(f"{self.name}.{phase}: failed: {error!r}")
        finally:
            self.app.stop()


def main():
    results.update(host_facts())
    for name in opts.sessions.split(","):
        Session(name).run()
    summary = {f"{r['session']}.{r['phase']}": {"key_p95_ms": (r.get("key_to_frame_ms") or {}).get("p95"),
                                                 "missed_frames": (r.get("frames") or {}).get("missed") if isinstance(r.get("frames"), dict) else None,
                                                 "stalls": (r.get("hangs") or {}).get("count") if isinstance(r.get("hangs"), dict) else None,
                                                 "stress_shape_missed": r.get("stress_shape_missed")}
               for r in results["runs"]}
    results["summary"] = summary
    note(f"SCRIPT-STORM {json.dumps(summary)} displays {results.get('displays')}")
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)


if __name__ == "__main__":
    main()
