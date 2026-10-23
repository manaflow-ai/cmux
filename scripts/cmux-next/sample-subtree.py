#!/usr/bin/env python3
"""Where the main thread spends a key's turn: the call tree of a `/usr/bin/sample` report under one
anchor frame (default `DebugKey.send`, the bench's synchronous key), as inclusive and self ms.

`sample PID SECONDS 1` takes one stack per ms, so a count is about a ms. Inclusive time of a
symbol counts only its outermost occurrence on each path (recursion is not double counted).

  sample-subtree.py REPORT [--anchor TEXT] [--top 40] [--json OUT]
"""
import argparse, collections, json, re, sys

LINE = re.compile(r"^(?P<lead>[\s+!:|]*?)(?P<count>\d+) (?P<symbol>.+?)(?:\s+\(in (?P<module>[^)]+)\))?(?:\s+\+ \d+.*|\s+\[0x[0-9a-f]+.*)?$")


def parse_main_thread(text):
    """[(depth, count, symbol, module)] of the report's main thread call tree."""
    rows, in_main = [], False
    for raw in text.splitlines():
        if re.match(r"^\s+\d+ Thread_\d+", raw):
            if in_main:
                break
            in_main = "main-thread" in raw or "Thread_" in raw and not rows and "DispatchQueue_1" in raw
            continue
        if not in_main:
            continue
        if not raw.strip() or raw.startswith("Total number"):
            if rows:
                break
            continue
        match = LINE.match(raw)
        if not match:
            continue
        rows.append((len(match.group("lead")), int(match.group("count")), match.group("symbol").strip(), match.group("module") or ""))
    return rows


def subtree(rows, anchor):
    """Inclusive and self counts of every symbol below each outermost `anchor` frame."""
    parent, child_sum = [None] * len(rows), [0] * len(rows)
    stack = []
    for i, (depth, count, _, _) in enumerate(rows):
        while stack and rows[stack[-1]][0] >= depth:
            stack.pop()
        if stack:
            parent[i] = stack[-1]
            child_sum[stack[-1]] += count
        stack.append(i)
    inclusive, own, total = collections.Counter(), collections.Counter(), 0
    for i, (_, count, symbol, _) in enumerate(rows):
        path, p = [], parent[i]
        while p is not None:
            path.append(rows[p][2])
            p = parent[p]
        if anchor in symbol and not any(anchor in s for s in path):
            total += count
        cut = next((k for k, s in enumerate(path) if anchor in s), None)
        if cut is None:
            continue
        inside = path[:cut]
        if symbol not in inside:
            inclusive[symbol] += count
        own[symbol] += max(0, count - child_sum[i])
    return total, inclusive, own


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument("--anchor", default="DebugKey.send")
    parser.add_argument("--top", type=int, default=40)
    parser.add_argument("--json")
    opts = parser.parse_args()
    rows = parse_main_thread(open(opts.report, errors="replace").read())
    total, inclusive, own = subtree(rows, opts.anchor)
    print(f"SUBTREE {opts.anchor}: {total} samples (~ms) on the main thread")
    for symbol, count in inclusive.most_common(opts.top):
        print(f"SUBTREE incl {count:6d}  {symbol[:170]}")
    for symbol, count in own.most_common(opts.top // 2):
        print(f"SUBTREE self {count:6d}  {symbol[:170]}")
    if opts.json:
        open(opts.json, "w").write(json.dumps({"anchor": opts.anchor, "total": total,
                                               "inclusive": inclusive.most_common(200), "self": own.most_common(100)}, indent=1))


if __name__ == "__main__":
    sys.exit(main())
