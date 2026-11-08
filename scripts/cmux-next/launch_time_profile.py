#!/usr/bin/env python3
"""A time profile of one cmux-next launch's main thread, split by the launch marks (bench-startup.py --time-profile).

The launch-stall sampler (debug.hangs) keeps one stack per stall, and inside applicationDidFinishLaunching the main
thread runs for about 300 ms with a different sampled frame on every run: it cannot say where most of that time goes.
This records the whole launch with Instruments' Time Profiler (`xctrace record --all-processes`, 1 ms samples of
every thread, started before the app is spawned so the first sample is the process's first), keeps the app's main
thread, and places each sample on the launch marks' clock (ms since process start).

Clock: the trace counts from its own start and the marks from the process start. The offset is taken from the
first main-thread sample whose stack holds `applicationDidFinishLaunching`, which lands within one sample of the
`did_finish_launching_start` mark; without one (an old build, no samples there) the app's first sample is the
process start. `clock` in the summary says which was used.

The summary (one dict per launch, `summarize`):
  window          [from_mark, to_mark] (default main_start .. first_window_frame_committed) and its length
  busy_ms         main-thread samples in the window that were running (not waiting in mach_msg, kevent, a lock)
  ours_inclusive  our frames (the app binary and its modules) by inclusive time in the window
  ours_leaf       each sample's leaf-most frame of ours: the function of ours that did (or called into) the work
  self            each sample's leaf frame of any binary, with the binary: where the CPU was
  binaries        self time by binary (Swift runtime, AppKit, SwiftUI, dyld, ours ...)
  tree            our frames top down (root first, other binaries' frames between them dropped), nodes over
                  TREE_MIN_MS, depth TREE_DEPTH
  gaps            each gap between consecutive marks in the window of GAP_MIN_MS or more: its busy time and its top
                  leaf-most frames of ours

`merge` takes the median over launches of each frame's time, so one run's outlier does not lead.

  launch_time_profile.py --self-test     the parser and the summary on a hand-written export
  launch_time_profile.py EXPORT.xml --pid N --marks marks.json   summarize an export already on disk
"""
import argparse
import collections
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

START_TIMEOUT_S = 60  # xctrace prints "Starting recording" once its instruments run
SAVE_TIMEOUT_S = 300  # after SIGINT, xctrace processes and saves the recording
EXPORT_TIMEOUT_S = 600
TREE_MIN_MS = 4.0
TREE_DEPTH = 14
GAP_MIN_MS = 8.0
TOP = 25
DFL_FRAME = "applicationDidFinishLaunching"
DFL_MARK = "did_finish_launching_start"
# Leaf frames of a thread that waits: the sample is not CPU work.
IDLE_LEAF = re.compile(r"mach_msg|__psynch_cvwait|__psynch_mutexwait|kevent|__semwait|__ulock_wait|__workq_kernreturn|"
                       r"__select|__pselect|poll$|__wait4|__read_nocancel|__open|semaphore_wait")
# Our binaries: the app's executable (`cmux DEV <tag>`, `cmux NEXT`, `cmux`) and its frameworks and debug dylib.
OURS_BINARY = re.compile(r"^(cmux|Cmux)|\.debug\.dylib$")
OURS_SYMBOL = re.compile(r"\bCmuxNext|\bcmux_|AppDelegate|AppServices")


class Recorder:
    """`xctrace record --template 'Time Profiler' --all-processes` into DIR/launch.trace. Started before the app is
    spawned; `interrupt` ends the recording (one SIGINT, as Ctrl-C), `stop` waits for the save."""

    def __init__(self, directory, cap_s=60):
        self.path = os.path.join(directory, "launch.trace")
        self.log_path = os.path.join(directory, "xctrace.log")
        self.cap_s = cap_s
        self.proc = None
        self.started = threading.Event()
        self.interrupted = False

    def command(self):
        return ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--all-processes", "--no-prompt",
                "--time-limit", f"{int(self.cap_s)}s", "--output", self.path]

    def start(self):
        log = open(self.log_path, "w")
        self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     bufsize=1, start_new_session=True)

        def read():
            for line in self.proc.stdout:
                log.write(line)
                log.flush()
                if "Starting recording" in line or "Ctrl-C to stop" in line:
                    self.started.set()
            log.close()
            self.started.set()

        threading.Thread(target=read, name="xctrace-log", daemon=True).start()
        self.started.wait(START_TIMEOUT_S)
        if self.proc.poll() is not None:
            raise RuntimeError(f"xctrace record exited {self.proc.returncode}: {self.log()[-600:]}")
        # "Starting recording" is printed as the instruments start: give the sampler a moment before the launch.
        time.sleep(1.0)  # measurement harness: a fixed lead before the spawn, not a wait on the app

    def log(self):
        try:
            with open(self.log_path) as f:
                return f.read()
        except OSError:
            return ""

    def interrupt(self):
        if not self.interrupted and self.proc is not None and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            self.interrupted = True

    def stop(self):
        """Ends the recording (if `interrupt` did not) and waits for the save; True when the trace exists."""
        if self.proc is None:
            return False
        self.interrupt()
        try:
            self.proc.wait(timeout=SAVE_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            self.proc.kill()  # the xctrace this recorder started, by its own handle
            self.proc.wait()
        return os.path.exists(self.path)

    def export(self, out_xml):
        """The trace's time-profile table as XML at `out_xml`; True when xctrace wrote it."""
        part = out_xml + ".part"
        try:
            done = subprocess.run(["xcrun", "xctrace", "export", "--input", self.path, "--xpath",
                                   '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", part],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=EXPORT_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return False
        if done.returncode == 0 and os.path.exists(part):
            os.replace(part, out_xml)
            return True
        return False


def _value(elem, vals):
    tag = elem.tag
    if tag == "frame":
        binary = next((vals.get(id(child)) for child in elem if child.tag == "binary"), None)
        return (elem.get("name") or elem.get("addr") or "?", binary or "")
    if tag == "binary":
        return elem.get("name") or os.path.basename(elem.get("path") or "") or ""
    if tag == "backtrace":
        return tuple(vals.get(id(child)) or ("?", "") for child in elem if child.tag == "frame")
    if tag in ("tagged-backtrace", "kperf-bt"):
        return next((vals.get(id(child)) for child in elem if child.tag == "backtrace"), ())
    if tag in ("tid", "pid"):
        try:
            return int(elem.text)
        except (TypeError, ValueError):
            return None
    if tag == "process":
        return {"pid": next((vals.get(id(child)) for child in elem if child.tag == "pid"), None)}
    if tag == "thread":
        process = next((vals.get(id(child)) for child in elem if child.tag == "process"), None) or {}
        fmt = elem.get("fmt") or ""
        pid = process.get("pid")
        if pid is None:
            match = re.search(r"pid:\s*(\d+)", fmt)
            pid = int(match.group(1)) if match else None
        return {"main": fmt.startswith("Main Thread"), "pid": pid}
    try:
        return int(elem.text)
    except (TypeError, ValueError):
        return elem.text


def main_thread_samples(xml_path, pid):
    """[(t_ns since the trace start, weight_ns, frames leaf first as (symbol, binary))] of `pid`'s main thread.
    Streams the export: an all-process table holds every thread of every process."""
    ids, vals, samples = {}, {}, []
    for event, elem in ET.iterparse(xml_path, events=("start", "end")):
        if event == "start":
            if elem.tag == "node":
                ids.clear()
            continue
        if elem.tag == "row":
            row = {child.tag: vals.get(id(child)) for child in elem}
            thread = row.get("thread")
            t = row.get("sample-time")
            if isinstance(thread, dict) and thread["main"] and thread["pid"] == pid and isinstance(t, int):
                weight = row.get("weight")
                stack = row.get("backtrace") or row.get("tagged-backtrace") or row.get("kperf-bt") or ()
                samples.append((t, weight if isinstance(weight, int) and weight > 0 else 1_000_000, stack))
            vals.clear()
            elem.clear()
            continue
        ref = elem.get("ref")
        value = ids.get(ref) if ref is not None else _value(elem, vals)
        if ref is None and elem.get("id") is not None:
            ids[elem.get("id")] = value
        vals[id(elem)] = value
    samples.sort(key=lambda s: s[0])
    return samples


def is_ours(frame):
    symbol, binary = frame
    return bool(OURS_BINARY.search(binary or "")) or (not binary and bool(OURS_SYMBOL.search(symbol or "")))


def short(symbol, limit=150):
    """A Swift symbol without its argument labels' noise: `closure #1 in Foo.bar(baz:)` stays readable."""
    symbol = re.sub(r"\s+", " ", symbol or "?")
    return symbol if len(symbol) <= limit else symbol[:limit - 1] + "…"


def align(samples, marks):
    """The trace time (ns) of the process start, and how it was found."""
    dfl = marks.get(DFL_MARK)
    if isinstance(dfl, (int, float)):
        for t, _, stack in samples:
            if any(DFL_FRAME in (symbol or "") for symbol, _ in stack):
                return t - int(dfl * 1e6), f"first sample in {DFL_FRAME} = {DFL_MARK} ({dfl} ms)"
    if samples:
        return samples[0][0], "the app's first main-thread sample = process start"
    return None, "no main-thread samples"


def summarize(samples, marks, from_mark="main_start", to_mark="first_window_frame_committed"):
    """One launch's main thread in [from_mark, to_mark] (ms since process start); see the module doc."""
    origin, clock = align(samples, marks)
    numeric = {k: v for k, v in marks.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    start = numeric.get(from_mark, 0.0)
    end = numeric.get(to_mark)
    summary = {"clock": clock, "window": [from_mark, to_mark], "samples": len(samples)}
    if origin is None or end is None:
        summary["error"] = "no samples" if origin is None else f"no {to_mark} mark"
        return summary
    inclusive, leaf, self_time, binaries = collections.Counter(), collections.Counter(), collections.Counter(), \
        collections.Counter()
    tree = {}
    busy = idle = 0.0
    edges = sorted((v, k) for k, v in numeric.items() if start <= v <= end)
    gap_busy = collections.Counter()
    gap_leaf = collections.defaultdict(collections.Counter)
    for t, weight, stack in samples:
        ms = (t - origin) / 1e6
        if ms < start or ms > end:
            continue
        w = weight / 1e6
        if not stack or IDLE_LEAF.search(stack[0][0] or ""):
            idle += w
            continue
        busy += w
        symbol, binary = stack[0]
        self_time[f"{short(symbol)}  [{binary or '?'}]"] += w
        binaries[binary or "?"] += w
        ours = [short(s) for s, b in stack if is_ours((s, b))]
        for name in set(ours):
            inclusive[name] += w
        top = ours[0] if ours else f"(not ours) {short(symbol)}  [{binary or '?'}]"
        leaf[top] += w
        node = tree
        for name in reversed(ours[-TREE_DEPTH:] if len(ours) > TREE_DEPTH else ours):
            entry = node.setdefault(name, [0.0, {}])
            entry[0] += w
            node = entry[1]
        # The gap this sample falls in: after the last mark at or before it.
        previous = None
        for value, name in edges:
            if value <= ms:
                previous = name
            else:
                break
        if previous is not None:
            gap_busy[previous] += w
            gap_leaf[previous][top] += w

    def rows(counter, limit=TOP):
        return [[name, round(ms, 1)] for name, ms in counter.most_common(limit)]

    def flatten(node, depth=0, out=None):
        out = [] if out is None else out
        for name, (ms, children) in sorted(node.items(), key=lambda item: -item[1][0]):
            if ms < TREE_MIN_MS:
                continue
            out.append([depth, name, round(ms, 1)])
            flatten(children, depth + 1, out)
        return out

    gaps = []
    for index, (value, name) in enumerate(edges):
        following = edges[index + 1] if index + 1 < len(edges) else (end, to_mark)
        length = following[0] - value
        if length >= GAP_MIN_MS and name != to_mark:
            gaps.append({"from": name, "to": following[1], "ms": round(length, 1), "busy_ms": round(gap_busy[name], 1),
                         "top": rows(gap_leaf[name], 6)})
    summary.update({"window_ms": round(end - start, 1), "busy_ms": round(busy, 1), "idle_ms": round(idle, 1),
                    "ours_inclusive": rows(inclusive, 40), "ours_leaf": rows(leaf), "self": rows(self_time),
                    "binaries": rows(binaries, 15), "tree": flatten(tree), "gaps": gaps})
    return summary


def merge(summaries):
    """The median over launches of each frame's time (a frame missing in a launch counts 0 there)."""
    good = [s for s in summaries if s and "error" not in s]
    if not good:
        return {"runs": 0}

    def median_of(key, limit=TOP):
        names = {name for s in good for name, _ in s.get(key, [])}
        values = {name: statistics.median([dict(s.get(key, [])).get(name, 0.0) for s in good]) for name in names}
        return [[name, round(ms, 1)] for name, ms in sorted(values.items(), key=lambda kv: -kv[1])[:limit]]

    return {"runs": len(good), "busy_ms": round(statistics.median(s["busy_ms"] for s in good), 1),
            "window_ms": round(statistics.median(s["window_ms"] for s in good), 1),
            "ours_leaf": median_of("ours_leaf"), "ours_inclusive": median_of("ours_inclusive", 40),
            "self": median_of("self"), "binaries": median_of("binaries", 15)}


def print_summary(label, summary, out=sys.stdout):
    """LAUNCH-PROFILE lines: the step log carries the answer, not only the JSON artifact."""
    p = lambda text: print(f"LAUNCH-PROFILE {label} {text}", file=out, flush=True)  # noqa: E731
    if "error" in summary:
        p(f"error: {summary['error']} ({summary.get('clock')})")
        return
    if "clock" in summary:
        p(f"clock: {summary['clock']}")
    p(f"window {summary.get('window_ms')} ms, main thread busy {summary.get('busy_ms')} ms, waiting "
      f"{summary.get('idle_ms', '-')} ms" + (f", {summary['runs']} runs (median)" if "runs" in summary else ""))
    for key, title in (("ours_leaf", "leaf-most frame of ours"), ("self", "leaf frame (any binary)"),
                       ("binaries", "self time by binary"), ("ours_inclusive", "inclusive, ours")):
        for name, ms in summary.get(key, [])[:TOP]:
            p(f"{title:24} {ms:7.1f} ms  {name}")
    for depth, name, ms in summary.get("tree", []):
        p(f"tree {ms:7.1f} ms {'  ' * depth}{name}")
    for gap in summary.get("gaps", []):
        top = "; ".join(f"{name} {ms}" for name, ms in gap["top"][:4])
        p(f"gap {gap['from']} -> {gap['to']}: {gap['ms']} ms, busy {gap['busy_ms']} ms: {top}")


SELF_TEST_XML = """<?xml version="1.0"?><trace-query-result><node xpath="x"><schema name="time-profile"/>
<row><sample-time id="1">5000000</sample-time><thread id="2" fmt="Main Thread 0x1a (cmux DEV t, pid: 42)"><tid id="3">26</tid><process id="4" fmt="cmux DEV t (42)"><pid id="5">42</pid></process></thread><weight id="6">1000000</weight><backtrace id="7"><frame id="8" name="dyld4::start"><binary id="9" name="dyld"/></frame></backtrace></row>
<row><sample-time id="10">15000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace id="11"><frame id="12" name="swift_conformsToProtocol"><binary id="13" name="libswiftCore.dylib"/></frame><frame id="14" name="CloudServices.init()"><binary id="15" name="cmux DEV t"/></frame><frame id="16" name="AppDelegate.applicationDidFinishLaunching(_:)"><binary ref="15"/></frame><frame id="17" name="main"><binary ref="15"/></frame></backtrace></row>
<row><sample-time id="18">16000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace ref="11"/></row>
<row><sample-time id="19">17000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace id="20"><frame id="21" name="mach_msg2_trap"><binary id="22" name="libsystem_kernel.dylib"/></frame><frame ref="16"/></backtrace></row>
<row><sample-time id="23">17000000</sample-time><thread id="24" fmt="Thread 0x1b (cmux DEV t, pid: 42)"><tid id="25">27</tid><process ref="4"/></thread><weight ref="6"/><backtrace ref="11"/></row>
<row><sample-time id="26">18000000</sample-time><thread ref="2"/><weight ref="6"/><backtrace id="27"><frame id="28" name="HomePage.makeTab()"><binary ref="15"/></frame><frame ref="16"/></backtrace></row>
</node></trace-query-result>"""


def self_test():
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "tp.xml")
        with open(path, "w") as f:
            f.write(SELF_TEST_XML)
        samples = main_thread_samples(path, 42)
        assert len(samples) == 5, samples  # the other thread's sample is not the main thread's
        assert samples[1][2][0] == ("swift_conformsToProtocol", "libswiftCore.dylib"), samples[1]
        assert main_thread_samples(path, 7) == []
        # did_finish_launching_start at 12 ms: the first sample in it is at trace 15 ms, so the process started at 3.
        marks = {"main_start": 1.0, DFL_MARK: 12.0, "dfl.services": 13.5, "first_window_frame_committed": 30.0}
        s = summarize(samples, marks)
        assert s["clock"].startswith("first sample in"), s
        assert s["busy_ms"] == 4.0 and s["idle_ms"] == 1.0, s  # dyld at 2 ms, the waiting sample at 14 ms
        assert s["ours_leaf"][0] == ["CloudServices.init()", 2.0], s["ours_leaf"]
        assert ["HomePage.makeTab()", 1.0] in s["ours_leaf"], s["ours_leaf"]
        assert dict(s["ours_inclusive"])["AppDelegate.applicationDidFinishLaunching(_:)"] == 3.0, s
        assert dict(s["binaries"])["libswiftCore.dylib"] == 2.0, s
        assert all(ms >= TREE_MIN_MS for _, _, ms in s["tree"]), s["tree"]
        gap = next(g for g in s["gaps"] if g["from"] == "dfl.services")
        assert gap["busy_ms"] == 1.0 and gap["to"] == "first_window_frame_committed", gap  # HomePage at 15 ms
        m = merge([s, s, {"error": "x"}])
        assert m["runs"] == 2 and m["ours_leaf"][0] == ["CloudServices.init()", 2.0], m
        # No dfl frame: the first sample is the process start.
        s2 = summarize(samples[:1] + samples[5:], {"main_start": 0.0, "first_window_frame_committed": 20.0})
        assert s2["clock"].startswith("the app's first"), s2
        print_summary("self-test", s, out=open(os.devnull, "w"))
    print("launch_time_profile self-test: ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", nargs="?")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--marks", help="a JSON file of {mark: ms since process start}")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not (args.export and args.pid and args.marks):
        parser.error("EXPORT, --pid and --marks (or --self-test)")
    with open(args.marks) as f:
        marks = json.load(f)
    summary = summarize(main_thread_samples(args.export, args.pid), marks)
    print_summary("export", summary)
    json.dump(summary, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
