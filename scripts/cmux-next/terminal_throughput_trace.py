#!/usr/bin/env python3
"""terminal-throughput-bench.py --trace: one Instruments recording (System Trace plus Time Profiler, every process) over
one burst, summarized per thread of the terminal's processes. CMUX-571: NEXT stays at 65-73 MB/s on every Mac while no
process is near one core, so the cap is a hand-off between processes, and a CPU sample cannot say which. The kernel's
thread states and system calls can: per thread, over the burst window (the writer's first to last run), the time it
ran, waited runnable and was blocked, its system calls (count, wall time, bytes the reads and writes returned) and its
heaviest top-of-stack frames. Each hop of the pipe (writer write, PTY read, the host's write to the daemon, the
daemon's read, its write to the app, the app's socket read) shows as one thread's read or write row: MB/s is its bytes
over the window, and its blocked share is its wall time in that call over the window.

The parser is pure (summarize_exports); Recorder drives xcrun xctrace on the Mac.
"""
import json, os, re, shutil, signal, subprocess, tempfile, threading, time
import xml.etree.ElementTree as ET

TEMPLATES = (["--template", "System Trace", "--instrument", "Time Profiler"], ["--template", "System Trace"],
             ["--template", "Time Profiler"])
# Tables read from the trace, by schema name (the first present of each group).
TABLE_GROUPS = (("thread-state",), ("syscall",), ("time-profile", "time-sample"))
IO_CALLS = {"read", "read_nocancel", "readv", "pread", "recvfrom", "recvmsg", "write", "write_nocancel", "writev",
            "pwrite", "sendto", "sendmsg", "sendmsg_x", "recvmsg_x"}
PROCESS_NAME = re.compile(r"^(.*?)\s*\((\d+)\)\s*$")
THREAD_PID = re.compile(r"pid:\s*(\d+)")


def _schema_cols(schema):
    cols = []
    for col in schema.findall("col"):
        cols.append(((col.findtext("mnemonic") or "").strip(), (col.findtext("engineering-type") or "").strip()))
    return cols


def read_table(path, on_row):
    """Calls on_row(cols, cells) per row of one `xctrace export --xpath ...table` XML (pure but for the file read):
    cols [(mnemonic, engineering type)], cells [{"fmt", "text", "name", "top"} or None], in column order, with every
    id/ref resolved. `top` is a backtrace's frame names, innermost first (at most 6)."""
    ids = {}
    cols = []

    def value(el):
        ref = el.get("ref")
        if ref is not None:
            return ids.get(ref)
        if el.tag == "sentinel":
            return None
        v = {"tag": el.tag, "fmt": el.get("fmt"), "text": (el.text or "").strip(), "name": el.get("name")}
        if el.tag in ("backtrace", "tagged-backtrace", "kperf-bt", "text-addresses"):
            frames = []
            for f in el.iter("frame"):
                fv = ids.get(f.get("ref")) if f.get("ref") is not None else {"name": f.get("name")}
                if fv and fv.get("name"):
                    frames.append(fv["name"])
                if len(frames) >= 6:
                    break
            v["top"] = frames
        if el.get("id") is not None:
            ids[el.get("id")] = v
        return v

    for event, el in ET.iterparse(path, events=("end",)):
        if el.tag == "schema":
            cols = _schema_cols(el)
        elif el.tag == "frame" and el.get("id") is not None:
            ids[el.get("id")] = {"name": el.get("name")}
        elif el.tag != "row" and el.get("id") is not None and el.get("id") not in ids:
            value(el)
        elif el.tag == "row":
            on_row(cols, [value(c) for c in list(el)])
            el.clear()


def _col(cols, *, types=(), names=()):
    for i, (mnemonic, etype) in enumerate(cols):
        if etype in types or mnemonic in names:
            return i
    return None


def _num(cell):
    if not cell:
        return None
    try:
        return int(cell["text"])
    except (ValueError, TypeError, KeyError):
        return None


def _label(cell):
    return (cell or {}).get("fmt") or (cell or {}).get("text") or "?"


def thread_pid(thread_fmt):
    m = THREAD_PID.search(thread_fmt or "")
    return int(m.group(1)) if m else None


def thread_process(thread_fmt):
    """`Main Thread 0x2a1 (cmux DEV x, pid: 61)` -> `cmux DEV x` (pure)."""
    m = re.search(r"\(([^()]*),\s*pid:\s*\d+\)\s*$", thread_fmt or "")
    return m.group(1).strip() if m else ""


class Rows:
    """Rows of the three tables, kept for the threads `keep(process name)` accepts (pure)."""

    def __init__(self, keep):
        self.keep = keep
        self.states = []    # (thread, start, end, state)
        self.calls = []     # (thread, start, end, name, returned bytes or None)
        self.samples = []   # (thread, time, weight, [frames])
        self.cols = {}

    def thread_state(self, cols, cells):
        self.cols.setdefault("thread-state", cols)
        t, s, d, st = (_col(cols, types=("thread",)), _col(cols, types=("start-time",)),
                       _col(cols, types=("duration",)), _col(cols, types=("thread-state",), names=("state",)))
        if None in (t, s, d, st) or max(t, s, d, st) >= len(cells):
            return
        thread = _label(cells[t])
        if not self.keep(thread_process(thread)):
            return
        start, dur = _num(cells[s]), _num(cells[d])
        if start is None or dur is None:
            return
        self.states.append((thread, start, start + dur, _label(cells[st])))

    def syscall(self, cols, cells):
        self.cols.setdefault("syscall", cols)
        t, s, d = _col(cols, types=("thread",)), _col(cols, types=("start-time",)), _col(cols, types=("duration",))
        n = _col(cols, types=("syscall",), names=("syscall", "name", "call"))
        r = next((i for i, (m, e) in enumerate(cols) if "return" in m.lower() or "return" in e.lower()), None)
        if None in (t, s, d, n) or max(t, s, d, n) >= len(cells):
            return
        thread = _label(cells[t])
        if not self.keep(thread_process(thread)):
            return
        start, dur = _num(cells[s]), _num(cells[d])
        if start is None or dur is None:
            return
        name = _label(cells[n]).split("(")[0].strip().lstrip("_")
        ret = _num(cells[r]) if r is not None and r < len(cells) else None
        if ret is None and r is not None and r < len(cells) and cells[r]:
            m = re.match(r"^\s*(-?\d+)", cells[r].get("fmt") or "")
            ret = int(m.group(1)) if m else None
        self.calls.append((thread, start, start + dur, name, ret))

    def time_profile(self, cols, cells):
        self.cols.setdefault("time-profile", cols)
        t = _col(cols, types=("thread",))
        s = _col(cols, types=("sample-time", "start-time"), names=("time",))
        w = _col(cols, types=("weight", "duration"), names=("weight",))
        b = next((i for i, (m, e) in enumerate(cols) if "backtrace" in e or "stack" in m), None)
        if None in (t, s, b) or max(t, s, b) >= len(cells):
            return
        thread = _label(cells[t])
        if not self.keep(thread_process(thread)):
            return
        when = _num(cells[s])
        weight = (_num(cells[w]) if w is not None and w < len(cells) else None) or 1_000_000
        frames = (cells[b] or {}).get("top") or []
        if when is not None and frames:
            self.samples.append((thread, when, weight, frames))


def overlap(a0, a1, w0, w1):
    return max(0, min(a1, w1) - max(a0, w0))


def burst_window(rows, writer_match):
    """(start, end) ns of the burst: the writer's first to last Running interval, the writer being the kept
    process `writer_match` accepts that wrote the most bytes (else ran the longest) (pure)."""
    by_proc = {}
    for thread, _, _, name, ret in rows.calls:
        if name.startswith("write") and ret and ret > 0 and writer_match(thread_process(thread)):
            pid = thread_pid(thread)
            by_proc[pid] = by_proc.get(pid, 0) + ret
    if not by_proc:
        for thread, a, b, state in rows.states:
            if state == "Running" and writer_match(thread_process(thread)):
                pid = thread_pid(thread)
                by_proc[pid] = by_proc.get(pid, 0) + (b - a)
    if not by_proc:
        return None, None
    writer = max(by_proc, key=by_proc.get)
    spans = [(a, b) for thread, a, b, state in rows.states if state == "Running" and thread_pid(thread) == writer]
    if not spans:
        spans = [(a, b) for thread, a, b, name, ret in rows.calls
                 if thread_pid(thread) == writer and name.startswith("write")]
    if not spans:
        return None, writer
    return (min(a for a, _ in spans), max(b for _, b in spans)), writer


def summarize(rows, writer_match, top_threads=24):
    """Per thread over the burst window: ms per state, its I/O calls (count, wall ms, bytes, MB/s, mean bytes per call,
    blocked % = wall share of the window) and its heaviest top-of-stack frames (pure)."""
    window, writer = burst_window(rows, writer_match)
    if not window:
        return {"error": "no burst window (no writer rows in the trace)", "writer_pid": writer}
    w0, w1 = window
    span = max(1, w1 - w0)
    threads = {}

    def entry(thread):
        return threads.setdefault(thread, {"states_ms": {}, "calls": {}, "samples": {}, "sampled_ms": 0.0})

    for thread, a, b, state in rows.states:
        ns = overlap(a, b, w0, w1)
        if ns:
            st = entry(thread)["states_ms"]
            st[state] = st.get(state, 0) + ns / 1e6
    for thread, a, b, name, ret in rows.calls:
        ns = overlap(a, b, w0, w1)
        if not ns and not (w0 <= a < w1):
            continue
        c = entry(thread)["calls"].setdefault(name, {"count": 0, "wall_ms": 0.0, "bytes": 0})
        c["count"] += 1
        c["wall_ms"] += ns / 1e6
        if name in IO_CALLS and ret and ret > 0:
            c["bytes"] += ret
    for thread, when, weight, frames in rows.samples:
        if w0 <= when < w1:
            e = entry(thread)
            e["sampled_ms"] += weight / 1e6
            e["samples"][frames[0]] = e["samples"].get(frames[0], 0) + weight / 1e6
    out = []
    for thread, e in threads.items():
        running = e["states_ms"].get("Running", 0.0)
        calls = {}
        for name, c in sorted(e["calls"].items(), key=lambda kv: -kv[1]["wall_ms"])[:8]:
            row = {"count": c["count"], "wall_ms": round(c["wall_ms"], 1),
                   "blocked_pct": round(100 * c["wall_ms"] * 1e6 / span, 1)}
            if c["bytes"]:
                row.update(bytes=c["bytes"], mb_s=round(c["bytes"] / 1e6 / (span / 1e9), 1),
                           bytes_per_call=round(c["bytes"] / max(1, c["count"])))
            calls[name] = row
        out.append({"thread": thread[:160], "pid": thread_pid(thread),
                    "running_pct": round(100 * running * 1e6 / span, 1),
                    "states_ms": {k: round(v, 1) for k, v in sorted(e["states_ms"].items(), key=lambda kv: -kv[1])},
                    "calls": calls,
                    "top_of_stack_ms": [[n[:120], round(ms, 1)]
                                        for n, ms in sorted(e["samples"].items(), key=lambda kv: -kv[1])[:6]]})
    io_ms = lambda t: sum(c.get("wall_ms", 0) for c in t["calls"].values())
    out.sort(key=lambda t: -(t["running_pct"] + 100 * io_ms(t) * 1e6 / span))
    return {"window_s": round(span / 1e9, 3), "writer_pid": writer, "threads": out[:top_threads]}


def summarize_exports(exports, keep, writer_match):
    """exports: {schema: xml path}. The burst summary of the kept threads (pure but for the file reads)."""
    rows = Rows(keep)
    handlers = {"thread-state": rows.thread_state, "syscall": rows.syscall, "time-profile": rows.time_profile,
                "time-sample": rows.time_profile}
    for schema, path in exports.items():
        if schema in handlers:
            read_table(path, handlers[schema])
    got = summarize(rows, writer_match)
    got["rows"] = {"thread_state": len(rows.states), "syscall": len(rows.calls), "samples": len(rows.samples)}
    got["columns"] = {k: [m or e for m, e in v] for k, v in rows.cols.items()}
    return got


def hop_lines(summary):
    """One line per I/O row with bytes, busiest first: what each hop moved and how long it waited (pure)."""
    lines = []
    for t in summary.get("threads", []):
        for name, c in t["calls"].items():
            if c.get("bytes"):
                lines.append((c["bytes"], f"{t['thread'][:90]} | {name} | {c['mb_s']} MB/s | "
                                          f"{c['bytes_per_call']} B/call | blocked {c['blocked_pct']}% | "
                                          f"running {t['running_pct']}%"))
    return [line for _, line in sorted(lines, reverse=True)]


class Recorder:
    """xcrun xctrace record over every process until stop(); then the exported tables, summarized."""

    def __init__(self, out_dir, label, limit_s=120):
        self.out_dir, self.label = out_dir, label
        self.tmp = tempfile.mkdtemp(prefix="tput-xctrace-")  # Instruments' ktrace intermediates (GBs) go here
        self.path = os.path.join(self.tmp, f"{label}.trace")
        self.log, self.proc, self.template, self.error = [], None, None, None
        for args in TEMPLATES:
            if self._start(args, limit_s):
                self.template = " ".join(a for a in args if not a.startswith("--"))
                return
        self.error = "xctrace record did not start: " + " | ".join(self.log[-6:])[:600]

    def _start(self, args, limit_s):
        shutil.rmtree(self.path, ignore_errors=True)
        argv = ["xcrun", "xctrace", "record", *args, "--all-processes", "--time-limit", f"{limit_s}s",
                "--output", self.path, "--no-prompt"]
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                env={**os.environ, "TMPDIR": self.tmp + "/"}, start_new_session=True)
        started = threading.Event()

        def pump():
            for line in proc.stdout:
                self.log.append(line.rstrip())
                if "ctrl-c" in line.lower() or "starting recording" in line.lower():
                    started.set()
        threading.Thread(target=pump, daemon=True).start()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not started.is_set() and proc.poll() is None:
            started.wait(0.25)
        if proc.poll() is not None or not started.is_set():
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)  # the recorder this object started
                try:
                    proc.wait(60)
                except subprocess.TimeoutExpired:
                    proc.kill()
            self.log.append(f"[{' '.join(args)}] exit {proc.poll()}")
            return False
        time.sleep(1.5)  # test harness: recording is under way before the burst starts
        self.proc = proc
        return True

    def stop(self, keep, writer_match):
        if not self.proc:
            return {"error": self.error}
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(600)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        summary = {"template": self.template}
        try:
            toc = subprocess.run(["xcrun", "xctrace", "export", "--input", self.path, "--toc"], capture_output=True,
                                 text=True, timeout=600).stdout
            schemas = sorted(set(re.findall(r'schema="([^"]+)"', toc)))
            summary["schemas"] = schemas
            exports = {}
            for group in TABLE_GROUPS:
                schema = next((s for s in group if s in schemas), None)
                if not schema:
                    continue
                xml = os.path.join(self.tmp, f"{schema}.xml")
                with open(xml, "w") as f:
                    subprocess.run(["xcrun", "xctrace", "export", "--input", self.path, "--xpath",
                                    f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                                   stdout=f, stderr=subprocess.DEVNULL, timeout=1200)
                exports[schema] = xml
                summary.setdefault("export_mb", {})[schema] = round(os.path.getsize(xml) / 1e6, 1)
            summary.update(summarize_exports(exports, keep, writer_match))
        except (subprocess.TimeoutExpired, OSError, ET.ParseError) as e:
            summary["error"] = f"{type(e).__name__}: {e}"[:400]
        finally:
            summary["recorder_log"] = self.log[-8:]
            shutil.rmtree(self.tmp, ignore_errors=True)
        with open(os.path.join(self.out_dir, f"trace-{self.label}.json"), "w") as f:
            json.dump(summary, f, indent=1)
        return summary
