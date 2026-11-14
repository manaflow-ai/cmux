#!/usr/bin/env python3
"""Per-thread wakeups of one process at rest, with each thread's name: what `bench_memory.py --attribute`
cannot say from rusage (one wakeup count for the whole process) or from thread CPU time (no count, and no
name for an unnamed thread).

`record(pid, seconds)` runs Instruments' System Trace attached to the process for `seconds`
(`xcrun xctrace record --template 'System Trace' --attach PID --time-limit Ns`), exports its
`thread-state` table and counts, per thread, how often it went from waiting to running (a wakeup) and
how long it ran. The trace is written into a fresh temporary folder and removed before the call returns.

`sample_threads(text)` reads a `/usr/bin/sample` report: for each thread its header (pthread name or
dispatch queue) and the first frames of its heaviest stack, so a thread that has no pthread name (a GCD
worker, a Rust thread spawned without a name) still gets a label: `label(tid, name, sampled)`.

Both join on the 64-bit thread id: `proc_pidinfo` PROC_PIDTHREADID64INFO, the trace's `<tid>` and
sample's `Thread_<id>` are the same number.
"""
from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import tempfile
import xml.etree.ElementTree as ET

RECORD_GRACE_S = 180  # after --time-limit, xctrace processes and saves the recording
EXPORT_TIMEOUT_S = 300
# Thread states: a thread that was waiting and then runs (directly or through Runnable) woke once; a
# preempted thread that runs again is the same run going on.
ON_CORE = ("running",)
PREEMPTED = ("preempted",)
READY = ("runnable",)
SYSTEM_FRAMES = re.compile(r"^(?:thread_start|_pthread_start|start_wqthread|_pthread_wqthread|"
                           r"std::sys::pal::unix::thread::Thread::new::thread_start|"
                           r"std::sys::.*thread_start|core::ops::function::FnOnce::call_once.*|"
                           r"__rust_begin_short_backtrace.*|_dispatch_worker_thread\d?|_dispatch_root_queue_drain)$")


def _value(elem, vals):
    tag = elem.tag
    if tag in ("tid", "pid"):
        try:
            return int(elem.text)
        except (TypeError, ValueError):
            return None
    if tag == "thread":
        tid = next((vals.get(id(child)) for child in elem if child.tag == "tid"), None)
        pid = next((vals.get(id(child)).get("pid") for child in elem
                    if child.tag == "process" and isinstance(vals.get(id(child)), dict)), None)
        fmt = elem.get("fmt") or ""
        # `Main Thread 0x1a (cmux DEV, pid: 42)` or `Main Thread (0x10f45bf) (fixture, pid: 7)`; an
        # unnamed thread is only its id: `0x3f42a5 (cmux DEV, pid: 42)`.
        match = re.match(r"^(.*?)\s*\(?0x[0-9a-fA-F]+\)?\s*\(", fmt)
        return {"tid": tid, "pid": pid, "name": (match.group(1).strip() if match else "")}
    if tag == "process":
        pid = next((vals.get(id(child)) for child in elem if child.tag == "pid"), None)
        return {"pid": pid}
    if tag == "duration":
        try:
            return int(elem.text)
        except (TypeError, ValueError):
            return 0
    return (elem.get("fmt") or elem.text or "").strip()


def table_rows(path):
    """Each row of an `xctrace export --xpath ...table[@schema=...]` file as {mnemonic: value}, `ref`s
    resolved, streamed (a busy process has many rows)."""
    ids, vals, columns = {}, {}, []
    for event, elem in ET.iterparse(path, events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                ids.clear()
            continue
        if elem.tag == "schema":
            columns = [(col.findtext("mnemonic") or "").strip() for col in elem.findall("col")]
            continue
        if elem.tag == "row":
            row = {}
            for index, child in enumerate(list(elem)):
                key = columns[index] if index < len(columns) and columns[index] else child.tag
                row[key] = None if child.tag == "sentinel" else vals.get(id(child))
                if child.tag != "sentinel":
                    row.setdefault("@" + child.tag, vals.get(id(child)))
            yield row
            vals.clear()
            elem.clear()
            continue
        ref = elem.get("ref")
        value = ids.get(ref) if ref is not None else _value(elem, vals)
        if ref is None and elem.get("id") is not None:
            ids[elem.get("id")] = value
        vals[id(elem)] = value


def count_wakes(path, pid=None):
    """{tid: {"name", "wakes", "runs", "running_ns"}} from an exported thread-state table: `wakes` counts the
    intervals in Running that follow a wait (Blocked, Waiting, Suspended..., with or without Runnable between) or open the
    thread's record; `runs` every Running interval. Threads of other processes are left out when `pid` is
    given."""
    threads, last = {}, {}
    for row in table_rows(path):
        thread = row.get("thread") or row.get("@thread")
        if not isinstance(thread, dict) or thread.get("tid") is None:
            continue
        if pid is not None and thread.get("pid") not in (None, pid):
            continue
        state = row.get("state") or row.get("@thread-state") or ""
        state = str(state).strip().lower()
        tid = thread["tid"]
        entry = threads.setdefault(tid, {"name": thread.get("name") or "", "wakes": 0, "runs": 0, "running_ns": 0})
        if not entry["name"] and thread.get("name"):
            entry["name"] = thread["name"]
        # `last` is the thread's state before it became ready: a wait (Blocked → Runnable → Running is
        # one wakeup) or running (Running → Preempted → Running is the same run going on).
        if state.startswith(ON_CORE):
            entry["runs"] += 1
            duration = row.get("duration") or row.get("@duration") or 0
            entry["running_ns"] += duration if isinstance(duration, int) else 0
            if not last.get(tid, "").startswith(ON_CORE):
                entry["wakes"] += 1
            last[tid] = "running"
        elif state.startswith(PREEMPTED):
            last[tid] = "running"
        elif not state.startswith(READY):
            last[tid] = state
    return threads


def _run_bounded(command, timeout):
    """Runs `command` in its own process group; on a timeout ends that group (only this call's own child)."""
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGINT)
        try:
            out, _ = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, _ = proc.communicate()
        return 124, out or ""
    return proc.returncode, out or ""


def record(pid: int, seconds: int = 10) -> dict:
    """{"seconds", "threads": {tid: {...}}} for `pid`, or {"error": ...}. Nothing is left on disk."""
    scratch = tempfile.mkdtemp(prefix=f"thread-wakes-{pid}-")
    try:
        trace = os.path.join(scratch, "rest.trace")
        rc, log = _run_bounded(["xcrun", "xctrace", "record", "--template", "System Trace", "--attach", str(pid),
                                "--time-limit", f"{int(seconds)}s", "--no-prompt", "--output", trace],
                               seconds + RECORD_GRACE_S)
        if not os.path.exists(trace):
            return {"error": f"xctrace record rc {rc}: {log.strip()[-300:]}"}
        table = os.path.join(scratch, "thread-state.xml")
        rc, log = _run_bounded(["xcrun", "xctrace", "export", "--input", trace, "--output", table, "--xpath",
                                '/trace-toc/run[@number="1"]/data/table[@schema="thread-state"]'], EXPORT_TIMEOUT_S)
        if not os.path.exists(table):
            return {"error": f"xctrace export rc {rc}: {log.strip()[-300:]}"}
        threads = count_wakes(table, pid)
        if not threads:
            return {"error": f"no thread-state rows for pid {pid} ({os.path.getsize(table)} bytes exported)"}
        return {"seconds": seconds, "threads": threads}
    except (OSError, ET.ParseError) as error:
        return {"error": str(error)[:300]}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


HEADER = re.compile(r"^\s{4}(\d+) Thread_(\d+)(.*)$")
FRAME = re.compile(r"^[\s+!:|]*\d+\s+(.+?)\s+\(in ([^)]+)\)")


def sample_threads(text: str, frames: int = 6) -> dict:
    """{tid: {"header", "frames"}} from a `sample` report's call graph: the header's text after the thread
    id (`: name`, `DispatchQueue_1: com.apple.main-thread  (serial)`), and the heaviest path's first frames
    past the thread-start boilerplate, as `symbol (binary)`."""
    out, tid = {}, None
    for line in text.splitlines():
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            break
        header = HEADER.match(line)
        if header:
            tid = int(header.group(2))
            out[tid] = {"header": header.group(3).strip().lstrip(":").strip(), "frames": [], "depth": None}
            continue
        if tid is None:
            continue
        frame = FRAME.match(line)
        if not frame:
            continue
        entry = out[tid]
        # The heaviest path is each level's first child: a frame indented deeper than the last kept one.
        depth = len(line) - len(line.lstrip(" +!:|"))
        if entry["depth"] is not None and depth <= entry["depth"]:
            continue
        entry["depth"] = depth
        symbol = re.sub(r"\s+\+\s+\d+.*$", "", frame.group(1)).strip()
        if SYSTEM_FRAMES.match(symbol) or len(entry["frames"]) >= frames:
            continue
        entry["frames"].append(f"{symbol[:90]} ({frame.group(2)})")
    for entry in out.values():
        entry.pop("depth", None)
    return out


def summarize(got: dict, sampled: dict, top: int = 40) -> dict:
    """`record`'s threads as report rows, most wakeups first, each named by `label` from `sampled`
    (`sample_threads` of the same process)."""
    seconds = got["seconds"]
    rows = [{"thread": tid, "label": label(t["name"], sampled.get(tid)),
             "wakes_per_s": round(t["wakes"] / seconds, 2), "runs_per_s": round(t["runs"] / seconds, 2),
             "cpu_ms_per_s": round(t["running_ns"] / 1e6 / seconds, 3),
             "frames": (sampled.get(tid) or {}).get("frames", [])[:4]}
            for tid, t in got["threads"].items() if t["runs"]]
    rows.sort(key=lambda r: (-r["wakes_per_s"], r["thread"]))
    return {"seconds": seconds, "threads": rows[:top],
            "total_wakes_per_s": round(sum(t["wakes"] for t in got["threads"].values()) / seconds, 2)}


def label(name: str, sampled: dict | None) -> str:
    """A thread's name for a report: its pthread name, else its sample header, else its first frames."""
    name = (name or "").strip()
    if name and name != "?":
        return name
    if sampled:
        if sampled.get("header"):
            return sampled["header"]
        if sampled.get("frames"):
            return "~" + " > ".join(f.split(" (")[0][:48] for f in sampled["frames"][:3])
    return "?"
