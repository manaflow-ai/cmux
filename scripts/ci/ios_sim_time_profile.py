#!/usr/bin/env python3
"""Summarize an `xctrace export` of a Time Profiler table, per process and main thread.

  python3 -I scripts/ci/ios_sim_time_profile.py TABLE.xml --markdown OUT.md --json OUT.json

TABLE.xml is the export of the trace's time-profile table:

  xcrun xctrace export --input X.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'

Each <row> is one sample: a thread (whose fmt names the process and pid, "Main Thread" for
the main thread), a weight (nanoseconds of CPU) and a backtrace, leaf frame first. The export
writes each value once with id="N" and points at it later with ref="N"; this resolves those
while streaming, so a large trace never sits in memory as a tree.

The summary groups samples by process name (an app relaunched by a UI test keeps one name
across its pids) and lists, for each process with main-thread samples, the symbols with the
most main-thread time: self (the leaf frame) and total (anywhere in the stack, once per
sample). cmux-next-ios-sim.sh runs it for `test ui=... profile`.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import re
import sys
import xml.etree.ElementTree as ET

THREAD_FMT = re.compile(r"\((?P<process>.+), pid: (?P<pid>\d+)\)\s*$")
PROCESS_FMT = re.compile(r"^(?P<process>.+?) \((?P<pid>\d+)\)$")
KEPT = frozenset({"thread", "process", "weight", "backtrace", "tagged-backtrace", "frame", "binary"})
DEFAULT_WEIGHT_NS = 1_000_000  # Time Profiler's default 1 ms interval, when a row has no weight.


class Table:
    """Streams rows of one exported table, resolving id/ref values."""

    def __init__(self):
        self.memo: dict[str, object] = {}

    def value(self, el):
        ref = el.get("ref")
        if ref is not None:
            return self.memo.get(ref)
        # Children first, so every id inside this element is known before a later ref.
        children = [(child.tag, self.value(child)) for child in el]
        tag = el.tag
        if tag == "frame":
            name = el.get("name")
            if not name:
                binary = next((v for t, v in children if t == "binary"), None)
                name = f"{el.get('addr', '?')}" + (f" ({binary})" if binary else "")
            v = name
        elif tag == "binary":
            v = el.get("name") or el.get("fmt") or "?"
        elif tag == "backtrace":
            v = tuple(v for t, v in children if t == "frame" and v is not None)
        elif tag == "tagged-backtrace":
            v = next((v for t, v in children if t == "backtrace"), ())
        elif tag == "thread":
            process = next((v for t, v in children if t == "process"), None)
            v = {"fmt": el.get("fmt", ""), "process": process}
        elif tag == "process":
            v = el.get("fmt", "")
        elif tag == "weight":
            try:
                v = int((el.text or "").strip())
            except ValueError:
                v = DEFAULT_WEIGHT_NS
        else:
            v = el.get("fmt") or (el.text or "").strip()
        # Rows refer back to these; a sample's own time (a new id every row) is never kept,
        # so memory grows with distinct threads and stacks, not with samples.
        if tag in KEPT and el.get("id") is not None:
            self.memo[el.get("id")] = v
        return v

    def row(self, el):
        thread, weight, stack = None, None, ()
        for child in el:
            v = self.value(child)
            if child.tag == "thread":
                thread = v
            elif child.tag == "weight":
                weight = v
            elif child.tag in ("backtrace", "tagged-backtrace"):
                stack = v or ()
        return thread, weight if isinstance(weight, int) else DEFAULT_WEIGHT_NS, stack


def process_of(thread) -> tuple[str, str]:
    if not thread:
        return "?", "?"
    if thread.get("process"):
        m = PROCESS_FMT.match(thread["process"])
        if m:
            return m["process"], m["pid"]
    m = THREAD_FMT.search(thread.get("fmt", ""))
    if m:
        return m["process"], m["pid"]
    return thread.get("process") or "?", "?"


def summarize(path: str, top: int = 25) -> dict:
    table = Table()
    procs: dict[str, dict] = defaultdict(lambda: {
        "pids": set(), "samples": 0, "weight_ns": 0, "main_samples": 0, "main_weight_ns": 0,
        "main_self": Counter(), "main_total": Counter(),
    })
    rows = 0
    stack_of_open: list = []
    for event, el in ET.iterparse(path, events=("start", "end")):
        if event == "start":
            stack_of_open.append(el)
            continue
        stack_of_open.pop()
        if el.tag != "row":
            continue
        parent = stack_of_open[-1] if stack_of_open else None
        thread, weight, frames = table.row(el)
        rows += 1
        name, pid = process_of(thread)
        p = procs[name]
        p["pids"].add(pid)
        p["samples"] += 1
        p["weight_ns"] += weight
        if thread and thread.get("fmt", "").startswith("Main Thread"):
            p["main_samples"] += 1
            p["main_weight_ns"] += weight
            if frames:
                p["main_self"][frames[0]] += weight
                for symbol in set(frames):
                    p["main_total"][symbol] += weight
        # Drop the processed row; values it defined stay in the memo.
        el.clear()
        if parent is not None:
            parent.remove(el)
    ms = lambda ns: round(ns / 1e6, 1)  # noqa: E731

    def ranked(counter: Counter) -> list[dict]:
        # Most time first; ties by name, so a summary is the same on every run.
        rows = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:top]
        return [{"symbol": s, "ms": ms(w)} for s, w in rows]
    out = {"rows": rows, "processes": []}
    for name, p in sorted(procs.items(), key=lambda kv: (-kv[1]["main_weight_ns"], -kv[1]["weight_ns"], kv[0])):
        out["processes"].append({
            "process": name,
            "pids": sorted(p["pids"]),
            "samples": p["samples"],
            "cpu_ms": ms(p["weight_ns"]),
            "main_thread_samples": p["main_samples"],
            "main_thread_ms": ms(p["main_weight_ns"]),
            "main_thread_self": ranked(p["main_self"]),
            "main_thread_total": ranked(p["main_total"]),
        })
    return out


def markdown(summary: dict, processes: int = 8, symbols: int = 15) -> str:
    def cell(text: str) -> str:
        return text.replace("|", "\\|").replace("\n", " ")

    lines = ["# Time Profiler: main-thread time by process", "",
             f"{summary['rows']} samples. Self is time in the leaf frame; total is time with the symbol "
             "anywhere on the main thread's stack (once per sample).", "",
             "| Process | pids | CPU ms | Main-thread ms | Main-thread samples |", "|---|---|---|---|---|"]
    for p in summary["processes"]:
        lines.append(f"| {cell(p['process'])} | {', '.join(p['pids'])} | {p['cpu_ms']} | "
                     f"{p['main_thread_ms']} | {p['main_thread_samples']} |")
    for p in [p for p in summary["processes"] if p["main_thread_samples"]][:processes]:
        lines += ["", f"## {cell(p['process'])}: main thread, {p['main_thread_ms']} ms", "",
                  "| Self ms | Symbol |", "|---|---|"]
        lines += [f"| {r['ms']} | `{cell(r['symbol'])}` |" for r in p["main_thread_self"][:symbols]]
        lines += ["", "| Total ms | Symbol |", "|---|---|"]
        lines += [f"| {r['ms']} | `{cell(r['symbol'])}` |" for r in p["main_thread_total"][:symbols]]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("table")
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--json", required=True)
    args = parser.parse_args(argv)
    summary = summarize(args.table)
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1)
        f.write("\n")
    with open(args.markdown, "w", encoding="utf-8") as f:
        f.write(markdown(summary))
    # A few lines for the step's SUMMARY.md: the processes with the most main-thread time.
    for p in [p for p in summary["processes"] if p["main_thread_samples"]][:5]:
        top = p["main_thread_self"][0] if p["main_thread_self"] else None
        print(f"{p['process']}: main thread {p['main_thread_ms']} ms of {p['cpu_ms']} ms CPU"
              + (f"; top self {top['symbol']} {top['ms']} ms" if top else ""))
    if not summary["rows"]:
        print("ios_sim_time_profile.py: the table has no samples", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
