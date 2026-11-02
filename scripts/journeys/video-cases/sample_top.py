#!/usr/bin/env python3
"""Top main-thread frames of a macOS `sample` report (RESIZE VIDEOS suite, F1 cause).

  sample_top.py diag-closesample.txt [--top 25] [--thread main]

Reads the call graph of the main thread (the "com.apple.main-thread" thread), drops the samples where it waits
in the run loop (mach_msg / __CFRunLoopServiceMachPort / kevent with nothing under them), and prints:
  busy        samples on the main thread that are not the idle wait (1 sample = the sample interval, 1 ms)
  inclusive   the frames with the most busy samples under them (cmux frames first)
  self        the frames that were on top of the stack most often while busy
Standard library only.
"""
import argparse
import re
import sys
from collections import Counter

LINE = re.compile(r"^(?P<indent>[ +!:|]*)(?P<count>\d+)\s+(?P<sym>.+?)\s*$")
IDLE = ("mach_msg2_trap", "mach_msg_trap", "__CFRunLoopServiceMachPort", "kevent", "__semwait_signal", "__psynch_cvwait",
        "__workq_kernreturn")


def clean(sym):
    sym = re.sub(r"\s+\(in [^)]+\)\s*\+\s*\d+.*$", "", sym)
    sym = re.sub(r"\s+\[0x[0-9a-f]+.*$", "", sym)
    return sym.strip()


def image(sym):
    m = re.search(r"\(in ([^)]+)\)", sym)
    return m.group(1) if m else ""


def main_thread_block(text, want):
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*\d+\s+Thread_\d+", line) and (want in line):
            start = i
            break
    if start is None:
        return []
    base = len(lines[start]) - len(lines[start].lstrip(" +!:|"))
    block = [lines[start]]
    for line in lines[start + 1:]:
        if not line.strip():
            break
        m = LINE.match(line)
        if not m or len(m.group("indent")) <= base:
            break
        block.append(line)
    return block


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--thread", default="com.apple.main-thread")
    opts = ap.parse_args()
    text = open(opts.report, errors="replace").read()
    block = main_thread_block(text, opts.thread)
    if not block:
        sys.exit(f"no {opts.thread} thread in {opts.report}")
    nodes = []  # (depth, count, sym, img)
    for line in block:
        m = LINE.match(line)
        if m:
            nodes.append((len(m.group("indent")), int(m.group("count")), clean(m.group("sym")), image(m.group("sym"))))
    total = nodes[0][1]
    # Each node's own samples: its count minus its direct children's counts.
    own = []
    for k, (depth, count, sym, img) in enumerate(nodes):
        child_depth, children = None, 0
        for d2, c2, _, _ in nodes[k + 1:]:
            if d2 <= depth:
                break
            if child_depth is None:
                child_depth = d2
            if d2 == child_depth:
                children += c2
        own.append(max(0, count - children))
    is_idle = [any(sym.startswith(i) for i in IDLE) for _, _, sym, _ in nodes]
    idle = sum(o for o, i in zip(own, is_idle) if i)
    selfc, busy_of = Counter(), Counter()
    stack = []
    for k, (depth, count, sym, img) in enumerate(nodes):
        while stack and stack[-1][0] >= depth:
            stack.pop()
        stack.append((depth, sym, img))
        if own[k] and not is_idle[k]:
            selfc[(sym, img)] += own[k]
            for key in {(s2, i2) for _, s2, i2 in stack}:
                busy_of[key] += own[k]
    busy = total - idle
    print(f"main thread: {total} samples, idle wait {idle}, busy {busy}")
    print("inclusive (busy samples under the frame), cmux and its frameworks first:")
    ranked = sorted(busy_of.items(), key=lambda kv: (-kv[1]))
    shown = 0
    for (sym, img), c in ranked:
        if img in ("libdyld.dylib", "dyld") or sym.startswith(("start", "main", "Thread_", "NSApplicationMain", "-[NSApplication run]")):
            continue
        print(f"  {c:6d}  {100 * c / max(1, busy):5.1f}%  {sym[:140]}  [{img}]")
        shown += 1
        if shown >= opts.top:
            break
    print("self (top of stack while busy):")
    for (sym, img), c in selfc.most_common(opts.top):
        print(f"  {c:6d}  {100 * c / max(1, busy):5.1f}%  {sym[:140]}  [{img}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
