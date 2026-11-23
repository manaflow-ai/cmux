#!/usr/bin/env python3
"""Main-thread self and inclusive sample counts from two `sample` files, and what is in A but not in B.

  sample_diff.py A.txt B.txt [--top 25]      (A = window resize, B = pane drag)

Counts are the main thread's samples (`sample` at 1 ms); the diff compares each symbol's share of the main thread's
samples in each capture, so a capture that got fewer samples (a loaded host) does not skew it.
"""
import argparse, re, sys
from collections import defaultdict

LINE = re.compile(r"^([ +!:|]*?)(\d+) (.*)$")
IDLE = ("mach_msg", "__CFRunLoopServiceMachPort", "mach_msg2_trap", "mach_msg_overwrite", "_dispatch_workloop_worker_thread", "kevent")


def symbol(text):
    text = re.sub(r"\s+\+\s+\d+\s+\[0x[0-9a-f]+\]\s*$", "", text)
    text = re.sub(r"\s+\[0x[0-9a-f]+\]\s*$", "", text)
    return text.strip()


def main_thread(path):
    nodes, stack, inside = [], [], False  # nodes: [depth, count, symbol, children_sum]
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\n")
        if "Call graph:" in line:
            continue
        if re.match(r"^\s+\d+ Thread_", line):
            inside = ("CrBrowserMain" in line or "com.apple.main-thread" in line) and "watchdog" not in line
            stack = []
            continue
        if line.startswith("Total number in stack") or line.startswith("Sort by top of stack"):
            inside = False
        if not inside:
            continue
        m = LINE.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        node = {"depth": depth, "count": int(m.group(2)), "sym": symbol(m.group(3)), "kids": 0, "path": ()}
        while stack and stack[-1]["depth"] >= depth:
            stack.pop()
        if stack:
            stack[-1]["kids"] += node["count"]
            node["path"] = stack[-1]["path"] + (stack[-1]["sym"],)
        stack.append(node)
        nodes.append(node)
    return nodes


def stats(nodes):
    self_, incl = defaultdict(int), defaultdict(int)
    total = busy = 0
    for n in nodes:
        s = n["count"] - n["kids"]
        self_[n["sym"]] += s
        if n["sym"] not in n["path"]:
            incl[n["sym"]] += n["count"]
        if not n["path"]:
            total += n["count"]
    idle = sum(c for sym, c in self_.items() if sym.split(" ")[0] in IDLE)
    return self_, incl, max(total, 1), max(total - idle, 1)


def top(table, n):
    return sorted(table.items(), key=lambda kv: -kv[1])[:n]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--top", type=int, default=25)
    o = ap.parse_args()
    (sa, ia, ta, ba), (sb, ib, tb, bb) = stats(main_thread(o.a)), stats(main_thread(o.b))
    print(f"main-thread samples: A total {ta}, busy (not in mach_msg wait) {ba} = {100*ba/ta:.0f}%; B total {tb}, busy {bb} = {100*bb/tb:.0f}%")
    ba, bb = ta, tb  # shares below are of the main thread's total samples in each capture
    for title, table, other, ba_, bb_ in (("SELF", sa, sb, ba, bb), ("INCLUSIVE", ia, ib, ba, bb)):
        print(f"\n== {title}: top in A (count A | count B | % of A | % of B)")
        for sym, c in top(table, o.top):
            print(f"{c:6d} | {other.get(sym, 0):6d} | {100*c/ba_:5.1f}% | {100*other.get(sym, 0)/bb_:5.1f}% | {sym[:150]}")
        print(f"\n== {title}: most in A and not in B (by share of the main thread samples)")
        diff = {sym: 100 * c / ba_ - 100 * other.get(sym, 0) / bb_ for sym, c in table.items()}
        for sym, d in top(diff, o.top):
            print(f"{d:+6.1f}pp | A {table[sym]:6d} | B {other.get(sym, 0):6d} | {sym[:150]}")
