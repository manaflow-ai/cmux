#!/usr/bin/env python3
"""Terminal throughput: one large output burst through a cmux NEXT terminal and through standalone Ghostty, on one Mac.

Leo, 2026-11-10: "we need to be adding more perf benchmarks". The CMUX-571 goal terminal-throughput reads the ratio
NEXT / Ghostty (target >= 1.0).

The same writer runs in both terminals: it reads a fixed payload (--mb MB of terminal text: plain lines, lines longer
than the grid, 256-color SGR runs, UTF-8) into memory, then writes it to its terminal in 64 KiB writes and waits with
tcdrain() until the terminal has read every byte off the PTY. MB/s is payload bytes / that time (1 MB = 10^6 bytes).
The terminal reads only as fast as it consumes, so the time is the terminal's, not the writer's; launch time and
font loading are outside it. Each terminal gets one warm-up burst (the first --warmup-mb MB), then --runs timed bursts;
the row is the median.

  NEXT     the tagged app (--app), launched once (bench_launch.BenchApp); each burst runs in a new focused terminal tab
           (action.run newTab with the writer as its command).
  Ghostty  the pinned standalone release (GHOSTTY_VERSION, sha256 checked; kept in $CI_SHARED_CACHE_DIR), or
           --ghostty-app. Each burst launches it with the writer as its command, the default config files off, and
           the grid NEXT's first burst reported (window-width/height in cells), so both draw the same columns and rows.

Rows (report.json `rows`, perf-cron.py kind budgets; reporting only, perf-cron.py judges no terminal.throughput row):
  terminal.throughput.next_mb_s, terminal.throughput.ghostty_mb_s (MB/s), terminal.throughput.ratio (x, NEXT/Ghostty).
Prints TERMINAL-THROUGHPUT lines. Exits 1 when a terminal gave no timed burst (the report says why in `missing`).

  terminal-throughput-bench.py --app "<cmux DEV tag.app>" --out DIR [--json FILE] [--mb 200] [--runs 3]
      [--warmup-mb 16] [--timeout 240] [--ghostty-app PATH] [--no-ghostty] [--breakdown] [--trace]

--trace (terminal_throughput_trace.py): the first timed burst of each terminal runs under one Instruments recording of
every process (System Trace and Time Profiler). Per thread of the terminal's processes, over the burst window: running,
runnable and blocked time, each system call's count, wall time and bytes, and the heaviest frames; one
TERMINAL-THROUGHPUT-HOP line per read or write row with bytes, which is each hop's MB/s and blocked share. The traced
burst runs slower than the others (the recording costs CPU); it is still a timed run.

--next-arm LABEL:CMUX_NEXT_NAME=VALUE (repeatable): before NEXT's own bursts, the same warm-up and timed bursts in
another launch of the same app with those launch variables (a daemon knob through DaemonDiagnosticKnobs set to its
old value), so a change behind a knob gets its before and after on one Mac in one step. Prints
TERMINAL-THROUGHPUT-ARM per arm; the report keeps them under next_arms; the rows stay NEXT's own.

--interrupt-runs N (default 3; 0 skips): ^C under a flood, NEXT only, after its timed bursts. MB/s says little about how
soon ^C stops the scroll (Dan Luu, "Terminal latency", 2017: terminals with high MB/s ignored ^C for minutes on a
flood). Per run a new tab runs FLOODER: it writes the payload in a loop with no end, and the script sends ^C
(terminal.sendText, the 0x03 byte) after --interrupt-flood-s s of it. The PTY's line discipline turns that byte into SIGINT;
the flooder stops writing at once and waits with tcdrain() until the terminal has read what it wrote. Per run:
  key_to_signal_ms     the script's send to the flooder's SIGINT: the input path (app, daemon, host, PTY) while output
                       floods the other way
  signal_to_drained_ms SIGINT to the PTY empty: output already written that the terminal still had to read
Both clocks are time.time() on one Mac. Bytes the daemon or app still hold past the PTY (and their drawing) are not
in either number. Rows: terminal.interrupt.key_to_signal_ms, terminal.interrupt.signal_to_drained_ms (median as p50,
worst as p95; reporting only). TERMINAL-THROUGHPUT-INTERRUPT per run.
"""
import argparse, hashlib, json, os, platform, random, shlex, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

GHOSTTY_VERSION = "1.4.0"
GHOSTTY_DMG_SHA256 = "3a02075dbd24318d778426af41dee5507d53ecc4578ede96912ec9ce6d18d3e8"
GHOSTTY_URL = f"https://release.files.ghostty.org/{GHOSTTY_VERSION}/Ghostty.dmg"
MB = 1_000_000
# The writer, run as the terminal's command. argv: payload, result file, bytes to write (0: all).
WRITER = r'''
import json, os, sys, termios, time
src, result, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, "rb") as f:
    data = f.read(limit) if limit > 0 else f.read()
try:
    cols, rows = os.get_terminal_size(1)
except OSError:
    cols = rows = None
view, n, off, chunk = memoryview(data), len(data), 0, 65536
t0 = time.perf_counter()
while off < n:
    off += os.write(1, view[off:off + chunk])
termios.tcdrain(1)
t1 = time.perf_counter()
os.write(1, b"\x1b[0m\r\nterminal-throughput: done\r\n")
tmp = result + ".tmp"
with open(tmp, "w") as f:
    json.dump({"bytes": n, "seconds": t1 - t0, "cols": cols, "rows": rows}, f)
os.rename(tmp, result)
'''
# --interrupt-runs: the flood, run as the terminal's command. argv: payload, result file. It writes `started` once the
# flood is under way and the result once ^C stopped it and the PTY drained.
FLOODER = r'''
import json, os, signal, sys, termios, time
src, result = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read(4 << 20)
got = {}
def on_int(signum, frame):
    got.setdefault("signal_at", time.time())
signal.signal(signal.SIGINT, on_int)
view, n, off, chunk, written, started = memoryview(data), len(data), 0, 65536, 0, False
while "signal_at" not in got:
    w = os.write(1, view[off:off + chunk])
    written += w
    off = (off + w) % n
    if not started and written >= 1 << 20:
        started = True
        open(result + ".started", "w").close()
termios.tcdrain(1)
got["drained_at"] = time.time()
os.write(1, b"\x1b[0m\r\nterminal-throughput: interrupted\r\n")
got["bytes"] = written
with open(result + ".tmp", "w") as f:
    json.dump(got, f)
os.rename(result + ".tmp", result)
'''
# --breakdown: where each burst's time goes. For every process of the terminal (the app, its daemon and terminal
# hosts, or Ghostty), over one window in the middle of the burst: its CPU and each of its threads' CPU (two `ps` reads,
# so a host that exits with its tab still counts), and one `sample` of it, summed by top-of-stack symbol with the idle
# waits left out. The stage that caps the rate shows as a thread near 100 %, and its symbols say what it does.
IDLE_FRAMES = ("__psynch_cvwait", "semaphore_wait_trap", "semaphore_timedwait_trap", "kevent", "kevent64", "kevent_id",
               "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn", "__accept", "__recvfrom", "__recvmsg", "poll",
               "__select", "__semwait_signal", "waitid", "__wait4", "__psynch_mutexwait", "__ulock_wait",
               "__ulock_wait2", "__sigsuspend", "read", "start_wqthread", "thread_start", "__open_nocancel")


def cpu_time_seconds(text):
    """Seconds in a `ps` CPU time: [D-][[H:]M:]S.ss (pure); None when it is not one."""
    days, _, clock = text.rpartition("-")
    seconds = 0.0
    try:
        for field in clock.split(":"):
            seconds = seconds * 60 + float(field)
        return seconds + float(days or 0) * 86400
    except ValueError:
        return None


def ps_cpu_seconds(text):
    """{pid: (cpu seconds, command)} from `ps -axo pid=,time=,command=` (pure)."""
    procs = {}
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        seconds = cpu_time_seconds(parts[1])
        if seconds is not None:
            procs[int(parts[0])] = (seconds, parts[2])
    return procs


def ps_thread_seconds(text):
    """Each thread's CPU seconds (system + user), in `ps -M -p PID` order (pure). Its rows end with STIME UTIME (and
    the command on the first row); the header and anything without two CPU times are skipped."""
    import re
    times = []
    for line in text.splitlines()[1:]:
        found = re.findall(r"(?<![\w.:-])(?:\d+-)?(?:\d+:)?\d+:\d+\.\d+(?![\w.:])", line)
        if len(found) >= 2:
            times.append(sum(cpu_time_seconds(t) or 0.0 for t in found[:2]))
    return times


def terminal_processes(match):
    """{pid: (cpu seconds, command)} of the processes whose command `match` accepts."""
    got = subprocess.run(["ps", "-axo", "pid=,time=,command="], capture_output=True, text=True)
    return {pid: v for pid, v in ps_cpu_seconds(got.stdout).items() if match(v[1]) and pid != os.getpid()}


def threads_of(pid):
    got = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True)
    return ps_thread_seconds(got.stdout)


def process_label(pid, command):
    """A process's name for the report (pure): its path inside an app bundle (`MacOS/cmux`,
    `Resources/bin/cmux-tui __terminal-host`) or its file name, its first plain argument, and its pid. Bundle paths
    hold spaces, so the command is cut at the bundle, not at the first space."""
    marker = ".app/Contents/"
    at = command.rfind(marker)
    rest = command[at + len(marker):] if at >= 0 else command
    argv = rest.split()
    name = argv[0] if at >= 0 and argv else os.path.basename(argv[0]) if argv else "?"
    sub = next((a for a in argv[1:3] if not a.startswith("-")), "")
    return f"{name} {sub}".strip() + f" [{pid}]"


def sample_summary(text, top=20):
    """The heaviest top-of-stack symbols from `sample` output with the idle waits left out, and their share of the
    samples of the busiest thread's worth (pure): `samples_per_thread` is one thread's sample count, so a symbol at
    that count is one core's time."""
    import re
    per_thread, heavy, in_top = 0, [], False
    for line in text.splitlines():
        m = re.match(r"^    (\d+) Thread_\d+", line)
        if m:
            per_thread = max(per_thread, int(m.group(1)))
            continue
        if line.startswith("Sort by top of stack"):
            in_top = True
            continue
        if in_top:
            m = re.match(r"^\s+(.+?)\s+(\d+)\s*$", line)
            if m:
                symbol = " ".join(m.group(1).split())
                if symbol.split(" (in ")[0] not in IDLE_FRAMES and len(heavy) < top:
                    heavy.append([symbol[:140], int(m.group(2))])
            elif not line.strip() and heavy:
                in_top = False
    busy = sum(n for _, n in heavy)
    return {"samples_per_thread": per_thread, "busy_cores": round(busy / per_thread, 2) if per_thread else None,
            "top_of_stack": heavy}


class Breakdown:
    """One burst's per-process and per-thread CPU over a window mid-burst, and a sample of each process."""

    def __init__(self, match, out_dir, label, delay=0.5, seconds=1):
        self.match, self.out_dir, self.label, self.delay, self.seconds = match, out_dir, label, delay, seconds
        self.window = None
        self.timer = __import__("threading").Thread(target=self._measure, daemon=True)
        self.timer.start()

    def _measure(self):
        time.sleep(self.delay)  # test harness: the window starts once the burst is under way
        before = terminal_processes(self.match)
        threads_before = {pid: threads_of(pid) for pid in before}
        started = time.monotonic()
        samplers = []
        for pid, (_, command) in before.items():
            path = os.path.join(self.out_dir, f"sample-{self.label}-{pid}.txt")
            samplers.append((pid, command, path, subprocess.Popen(
                ["/usr/bin/sample", str(pid), str(self.seconds), "-mayDie", "-file", path],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)))
        for _, _, _, proc in samplers:
            try:
                proc.wait(self.seconds + 30)
            except subprocess.TimeoutExpired:
                proc.terminate()  # the sampler this script started
        wall = time.monotonic() - started
        after = terminal_processes(self.match)
        procs = {}
        for pid, (seconds, command) in before.items():
            entry = {"cpu_pct": None, "threads_pct": []}
            if pid in after:
                entry["cpu_pct"] = round(100 * (after[pid][0] - seconds) / wall, 1)
                now = threads_of(pid)
                then = threads_before.get(pid, [])
                if len(now) >= len(then):
                    busy = sorted((100 * (b - a) / wall for a, b in zip(then, now)), reverse=True)
                    entry["threads_pct"] = [round(p, 1) for p in busy[:4]]
            path = next((p for q, _, p, _ in samplers if q == pid), None)
            if path and os.path.exists(path):
                with open(path, errors="replace") as f:
                    entry["sample"] = sample_summary(f.read())
            if entry["cpu_pct"] is None or entry["cpu_pct"] >= 2 or entry.get("sample", {}).get("top_of_stack"):
                procs[process_label(pid, command)] = entry
        self.window = {"window_s": round(wall, 2), "processes": procs}

    def finish(self, burst_seconds):
        self.timer.join(timeout=60)
        result = {"burst_s": round(burst_seconds, 3) if burst_seconds else None,
                  **(self.window or {"error": "the window did not finish"})}
        print("TERMINAL-THROUGHPUT-BREAKDOWN " + json.dumps({"terminal": self.label, **result}), flush=True)
        return result




def parse_arm(text):
    """`base:CMUX_NEXT_X=0,CMUX_NEXT_Y=1` -> ("base", {"CMUX_NEXT_X": "0", "CMUX_NEXT_Y": "1"}) (pure). Only
    CMUX_NEXT_* names: the app strips every other inherited CMUX variable, so any other name would measure nothing."""
    label, sep, pairs = text.partition(":")
    env = {}
    for pair in filter(None, pairs.split(",")):
        name, eq, value = pair.partition("=")
        if not eq or not name.startswith("CMUX_NEXT_"):
            raise ValueError(f"--next-arm {text!r}: {pair!r} is not CMUX_NEXT_NAME=VALUE")
        env[name] = value
    if not sep or not label or not env or not label.replace("-", "").isalnum():
        raise ValueError(f"--next-arm {text!r}: want LABEL:CMUX_NEXT_NAME=VALUE[,...]")
    return label, env


def is_python(process_name):
    """The writer's process as Instruments names it (/usr/bin/python3 runs as `Python`) (pure)."""
    return process_name.lower().startswith("python")


def start_trace(opts, i, terminal):
    """--trace: an Instruments recording over the first timed burst of `terminal` (terminal_throughput_trace.py)."""
    if not opts.trace or i != 1:
        return None
    from terminal_throughput_trace import Recorder
    return Recorder(opts.out, f"{terminal}-{i}")


def finish_trace(tracer, terminal, keep):
    """Stops `tracer`, prints its summary (TERMINAL-THROUGHPUT-TRACE) and one TERMINAL-THROUGHPUT-HOP line per I/O
    row with bytes, and returns the summary for the report."""
    from terminal_throughput_trace import hop_lines
    summary = tracer.stop(keep, is_python)
    print("TERMINAL-THROUGHPUT-TRACE " + json.dumps({"terminal": terminal, **summary}), flush=True)
    for line in hop_lines(summary):
        print(f"TERMINAL-THROUGHPUT-HOP {terminal} | {line}", flush=True)
    return summary


def payload_block(seed=571, size=1 << 20):
    """About `size` bytes of terminal text, the same every run (pure)."""
    rng = random.Random(seed)
    words = ["cargo", "build", "warning:", "error[E0308]:", "src/main.rs:42:7", "Compiling", "Finished", "test", "ok",
             "PASS", "FAIL", "0x7ffee4b2c8a0", "GET", "/api/v1/sessions", "200", "1.24ms", "INFO", "DEBUG", "--release"]
    utf8 = ["é", "ü", "→", "✓", "✗", "日本語", "│", "─", "λ", "🙂"]
    out, total = [], 0
    while total < size:
        kind = rng.random()
        if kind < 0.05:
            line = ""
        elif kind < 0.30:
            line = " ".join(f"\x1b[38;5;{rng.randrange(256)}m{rng.choice(words)}\x1b[0m" for _ in range(rng.randrange(4, 14)))
        elif kind < 0.40:
            line = " ".join(rng.choice(words + utf8) for _ in range(rng.randrange(6, 20)))
        else:
            line = " ".join(rng.choice(words) for _ in range(rng.randrange(6, 30)))  # some lines wrap a 120-column grid
        b = (line + "\n").encode()
        out.append(b)
        total += len(b)
    return b"".join(out)


def write_payload(path, mb):
    block, want = payload_block(), mb * MB
    with open(path, "wb") as f:
        left = want
        while left > 0:
            f.write(block[:left])
            left -= min(left, len(block))
    return want


def wait_result(path, timeout, alive=lambda: True):
    """The writer's result, or None after `timeout` s or once `alive()` is False (the terminal went away)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
        if not alive():
            time.sleep(0.5)  # the result may land just as the terminal exits
            if os.path.exists(path):
                with open(path) as f:
                    return json.load(f)
            return None
        time.sleep(0.2)  # test harness: the writer's result file is its only signal
    return None


def summarize(runs):
    rates = [r["mb_s"] for r in runs if isinstance(r.get("mb_s"), (int, float))]
    return round(statistics.median(rates), 1) if rates else None


def run_record(label, i, res):
    if not res or not res.get("seconds"):
        return {"run": i, "error": "no result"}
    rec = {"run": i, "bytes": res["bytes"], "seconds": round(res["seconds"], 4),
           "mb_s": round(res["bytes"] / MB / res["seconds"], 1), "cols": res.get("cols"), "rows": res.get("rows")}
    print("TERMINAL-THROUGHPUT " + json.dumps({"terminal": label, **rec}), flush=True)
    return rec


def interrupt_record(i, sent_at, res):
    """One ^C run's record (pure): the two spans in ms, or why there are none."""
    if sent_at is None or not res or "signal_at" not in res or "drained_at" not in res:
        return {"run": i, "error": "no result" if sent_at is not None else "no flood"}
    return {"run": i, "key_to_signal_ms": round(1000 * (res["signal_at"] - sent_at), 1),
            "signal_to_drained_ms": round(1000 * (res["drained_at"] - res["signal_at"]), 1),
            "flood_bytes": res.get("bytes")}


def measure_interrupts(opts, app, flooder, payload, scratch):
    """--interrupt-runs ^C runs in NEXT's running app, each in a new focused tab (FLOODER)."""
    runs = []
    for i in range(1, opts.interrupt_runs + 1):
        result = os.path.join(scratch, f"interrupt-{i}.json")
        cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-I", flooder, payload, result])
        app.rpc("action.run", {"action": "newTab", "args": {"name": f"interrupt-{i}", "focus": True, "command": cmd}})
        sent_at = None
        if wait_result_file(result + ".started", 30, alive=lambda: app.process.poll() is None):
            time.sleep(opts.interrupt_flood_s)  # test harness: the flood runs this long before the key
            sent_at = time.time()
            app.rpc("action.run", {"action": "terminal.sendText", "args": {"text": "\x03"}, "focus": True,
                                   "origin": "script"})
        res = wait_result(result, 60, alive=lambda: app.process.poll() is None) if sent_at else None
        rec = interrupt_record(i, sent_at, res)
        print("TERMINAL-THROUGHPUT-INTERRUPT " + json.dumps(rec), flush=True)
        runs.append(rec)
    return runs


def wait_result_file(path, timeout, alive=lambda: True):
    """True once `path` exists, False after `timeout` s or once `alive()` is False."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and alive():
        if os.path.exists(path):
            return True
        time.sleep(0.05)  # test harness: the flooder's marker file is its only signal
    return os.path.exists(path)


def measure_next(opts, writer, payload, scratch, label="next", env=None):
    """NEXT's bursts in one launch of the app; `env` adds to its launch environment (an --next-arm), `label` names
    the rows."""
    from bench_launch import BenchApp
    out = {"runs": []}
    app = BenchApp(opts.app, out=os.path.join(opts.out, label), env=env)
    try:
        app.launch()
        time.sleep(3)  # test harness: let the first window settle before the first burst
        plan = [("warmup", opts.warmup_mb * MB)] + [(i, 0) for i in range(1, opts.runs + 1)]
        for i, limit in plan:
            result = os.path.join(scratch, f"{label}-{i}.json")
            cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-I", writer, payload, result, str(limit)])
            tracer = start_trace(opts, i, "next") if label == "next" else None
            probe = (Breakdown(lambda c: opts.app in c or "cmux-tui" in c or "acpmux" in c or writer in c, opts.out,
                               f"{label}-{i}") if opts.breakdown and i != "warmup" and not tracer else None)
            tab = f"throughput-{i}" if label == "next" else f"throughput-{label}-{i}"
            reply = app.rpc("action.run", {"action": "newTab", "args": {"name": tab, "focus": True, "command": cmd}})
            if isinstance(reply, dict) and reply.get("error"):
                out["error"] = f"newTab: {reply['error']}"
                break
            res = wait_result(result, opts.timeout, alive=lambda: app.process.poll() is None)
            if tracer:
                out["trace"] = finish_trace(tracer, "next", lambda name: "cmux" in name or is_python(name))
            if probe:
                out.setdefault("breakdown", []).append(probe.finish((res or {}).get("seconds")))
            if i == "warmup":
                out["warmup"] = run_record(f"{label}-warmup", 0, res)
                continue
            out["runs"].append(run_record(label, i, res))
        if label == "next" and opts.interrupt_runs > 0 and "error" not in out:
            flooder = os.path.join(scratch, "flooder.py")
            with open(flooder, "w") as f:
                f.write(FLOODER)
            out["interrupts"] = measure_interrupts(opts, app, flooder, payload, scratch)
    except Exception as e:  # a failed launch (LaunchError printed its report) or a dead socket
        out["error"] = f"{type(e).__name__}: {e}"[:400]
    finally:
        app.stop()
    return out


def ghostty_app(opts, scratch):
    """(path to Ghostty.app, version) or (None, why)."""
    if opts.ghostty_app:
        return (opts.ghostty_app, "given") if os.path.isdir(opts.ghostty_app) else (None, f"no app at {opts.ghostty_app}")
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    home = os.path.join(cache_root, "ghostty-standalone", GHOSTTY_VERSION) if cache_root else os.path.join(scratch, "ghostty")
    app = os.path.join(home, "Ghostty.app")
    if os.path.isfile(os.path.join(home, "ok")) and os.path.isdir(app):
        return app, GHOSTTY_VERSION
    os.makedirs(home, exist_ok=True)
    dmg, mnt, tmp_app = os.path.join(scratch, "Ghostty.dmg"), os.path.join(scratch, "ghostty-mnt"), app + ".tmp"
    got = subprocess.run(["curl", "-fsSL", "--retry", "3", "--retry-all-errors", "-m", "600", "-o", dmg, GHOSTTY_URL],
                         capture_output=True, text=True)
    if got.returncode != 0:
        return None, f"download {GHOSTTY_URL}: {got.stderr.strip()[:200]}"
    with open(dmg, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != GHOSTTY_DMG_SHA256:
        return None, f"{GHOSTTY_URL} sha256 {digest}, want {GHOSTTY_DMG_SHA256}"
    os.makedirs(mnt, exist_ok=True)
    att = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt, dmg],
                         capture_output=True, text=True)
    if att.returncode != 0:
        return None, f"hdiutil attach: {att.stderr.strip()[:200]}"
    try:
        shutil.rmtree(tmp_app, ignore_errors=True)
        cp = subprocess.run(["ditto", os.path.join(mnt, "Ghostty.app"), tmp_app], capture_output=True, text=True)
        if cp.returncode != 0:
            return None, f"ditto: {cp.stderr.strip()[:200]}"
    finally:
        subprocess.run(["hdiutil", "detach", mnt, "-force"], capture_output=True)
    shutil.rmtree(app, ignore_errors=True)
    os.rename(tmp_app, app)
    open(os.path.join(home, "ok"), "w").close()
    return app, GHOSTTY_VERSION


def measure_ghostty(opts, writer, payload, scratch, grid):
    out = {"runs": []}
    app, version = ghostty_app(opts, scratch)
    if not app:
        out["error"] = version
        return out
    out["app"], out["version"] = app, version
    binary = os.path.join(app, "Contents", "MacOS", "ghostty")
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(scratch, "xdg"))
    cols, rows = grid if grid and all(grid) else (120, 40)
    out["grid_requested"] = [cols, rows]
    plan = [("warmup", opts.warmup_mb * MB)] + [(i, 0) for i in range(1, opts.runs + 1)]
    for i, limit in plan:
        result = os.path.join(scratch, f"ghostty-{i}.json")
        cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-I", writer, payload, result, str(limit)])
        argv = [binary, "--config-default-files=false", f"--command={cmd}", "--wait-after-command=false",
                "--quit-after-last-window-closed=true", "--confirm-close-surface=false", "--window-save-state=never",
                "--auto-update=off", f"--window-width={cols}", f"--window-height={rows}"]
        log = open(os.path.join(opts.out, f"ghostty-{i}.log"), "w")
        tracer = start_trace(opts, i, "ghostty")
        probe = (Breakdown(lambda c: app in c or writer in c, opts.out, f"ghostty-{i}", delay=0.8)
                 if opts.breakdown and i != "warmup" and not tracer else None)
        proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            res = wait_result(result, opts.timeout, alive=lambda: proc.poll() is None)
            if tracer:
                out["trace"] = finish_trace(tracer, "ghostty", lambda name: "ghostty" in name.lower() or is_python(name))
            if probe:
                out.setdefault("breakdown", []).append(probe.finish((res or {}).get("seconds")))
        finally:
            try:
                proc.wait(15)  # it quits once its last window closes
            except subprocess.TimeoutExpired:
                proc.terminate()  # the PID this script started
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            log.close()
        if i == "warmup":
            out["warmup"] = run_record("ghostty-warmup", 0, res)
            continue
        out["runs"].append(run_record("ghostty", i, res))
    return out


def interrupt_rows(runs):
    """The ^C rows (pure): per span, the median of the runs as p50 and the worst as p95; none without a good run."""
    rows = []
    for key in ("key_to_signal_ms", "signal_to_drained_ms"):
        vals = [r[key] for r in runs or [] if isinstance(r.get(key), (int, float))]
        if vals:
            rows.append({"name": f"terminal.interrupt.{key}", "p50": round(statistics.median(vals), 1),
                         "p95": max(vals), "unit": "ms", "budget": None, "floor": 1.0, "n": len(vals)})
    return rows


def report_rows(next_mb_s, ghostty_mb_s, interrupts=None):
    """The report's rows (pure): each MB/s median and their ratio, when both are known, and the ^C rows."""
    rows = interrupt_rows(interrupts)
    for name, v, unit in (("terminal.throughput.next_mb_s", next_mb_s, "MB/s"),
                          ("terminal.throughput.ghostty_mb_s", ghostty_mb_s, "MB/s")):
        if v is not None:
            rows.append({"name": name, "p50": v, "p95": v, "unit": unit, "budget": None, "floor": round(0.1 * v, 1)})
    if next_mb_s and ghostty_mb_s:
        ratio = round(next_mb_s / ghostty_mb_s, 3)
        rows.append({"name": "terminal.throughput.ratio", "p50": ratio, "p95": ratio, "unit": "x", "budget": None,
                     "floor": 0.1})
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring-terminal.py passes it; the app path names the tag
    parser.add_argument("--mb", type=int, default=200)
    parser.add_argument("--warmup-mb", type=int, default=16)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--ghostty-app")
    parser.add_argument("--no-ghostty", action="store_true")
    parser.add_argument("--breakdown", action="store_true",
                        help="per burst: CPU per process and a mid-burst sample of each (TERMINAL-THROUGHPUT-BREAKDOWN)")
    parser.add_argument("--trace", action="store_true",
                        help="the first timed burst of each terminal under Instruments (System Trace and Time Profiler): "
                             "per thread, its states, system calls and bytes over the burst (TERMINAL-THROUGHPUT-TRACE)")
    parser.add_argument("--interrupt-runs", type=int, default=3,
                        help="after NEXT's bursts, this many ^C-under-a-flood runs (TERMINAL-THROUGHPUT-INTERRUPT); 0 skips")
    parser.add_argument("--interrupt-flood-s", type=float, default=2.0, help="seconds of flood before each ^C")
    parser.add_argument("--next-arm", action="append", default=[], metavar="LABEL:NAME=VALUE[,NAME=VALUE]",
                        help="before NEXT's own bursts, the same bursts in another launch of the same app with these "
                             "launch variables (a daemon knob's off value): a same-Mac A/B in one step "
                             "(TERMINAL-THROUGHPUT-ARM, report next_arms)")
    opts = parser.parse_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="tput.", dir="/private/tmp" if os.path.isdir("/private/tmp") else None)
    try:
        writer = os.path.join(scratch, "writer.py")
        with open(writer, "w") as f:
            f.write(WRITER)
        payload = os.path.join(scratch, "payload.txt")
        size = write_payload(payload, opts.mb)
        report = {"suite": "terminal-throughput", "payload_bytes": size, "runs_per_terminal": opts.runs,
                  "host": platform.node(), "missing": []}
        arms = [parse_arm(a) for a in opts.next_arm]
        for arm, env in arms:
            got = measure_next(opts, writer, payload, scratch, label=f"next-{arm}", env=env)
            got["env"], got["median_mb_s"] = env, summarize(got["runs"])
            report.setdefault("next_arms", {})[arm] = got
        report["next"] = measure_next(opts, writer, payload, scratch)
        if arms:
            head = summarize(report["next"]["runs"])
            for arm, got in report["next_arms"].items():
                print("TERMINAL-THROUGHPUT-ARM " + json.dumps({
                    "arm": arm, "env": got["env"], "arm_mb_s": [r.get("mb_s") for r in got["runs"]],
                    "head_mb_s": [r.get("mb_s") for r in report["next"]["runs"]], "arm_median": got["median_mb_s"],
                    "head_median": head, "head_over_arm": round(head / got["median_mb_s"], 3)
                    if head and got["median_mb_s"] else None}), flush=True)
        first = next((r for r in report["next"]["runs"] if r.get("cols")), report["next"].get("warmup") or {})
        grid = (first.get("cols"), first.get("rows"))
        if opts.no_ghostty:
            report["ghostty"] = {"runs": [], "error": "--no-ghostty"}
        else:
            report["ghostty"] = measure_ghostty(opts, writer, payload, scratch, grid)
        next_mb_s, ghostty_mb_s = summarize(report["next"]["runs"]), summarize(report["ghostty"]["runs"])
        report["next"]["median_mb_s"], report["ghostty"]["median_mb_s"] = next_mb_s, ghostty_mb_s
        for label, v in (("next", next_mb_s), ("ghostty", ghostty_mb_s)):
            if v is None:
                report["missing"].append({"name": f"terminal.throughput.{label}_mb_s",
                                             "reason": report[label].get("error") or "no timed burst"})
        report["rows"] = report_rows(next_mb_s, ghostty_mb_s, report["next"].get("interrupts"))
        if opts.interrupt_runs > 0 and not any(r["name"].startswith("terminal.interrupt.") for r in report["rows"]):
            report["missing"].append({"name": "terminal.interrupt.key_to_signal_ms",
                                      "reason": report["next"].get("error") or "no ^C run gave a result"})
        if not report["missing"]:
            # Not `incomplete`: perf-cron.py reads that key as the whole measurement's coverage, and a Ghostty download
            # that failed must not keep the other parts' rows from a last good run.
            del report["missing"]
        print("TERMINAL-THROUGHPUT-SUMMARY " + json.dumps({"next_mb_s": next_mb_s, "ghostty_mb_s": ghostty_mb_s,
                                                           "ratio": next((r["p50"] for r in report["rows"]
                                                                          if r["name"].endswith(".ratio")), None),
                                                           "host": report["host"], "payload_mb": opts.mb}), flush=True)
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
        return 0 if next_mb_s is not None and (ghostty_mb_s is not None or opts.no_ghostty) else 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
