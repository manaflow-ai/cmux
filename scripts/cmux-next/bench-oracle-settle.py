#!/usr/bin/env python3
"""debug.oracle.settle latency over the control socket of a running DEV build (p15-oracle-031).

The refactor oracle settles after every step (plans/cmux-next/chrome-parity/p15-oracle.md, section 3B). This
bench sends --count settles (default 1,000) with `sequence: "sync"` (a real daemon round trip, the snapshot
barrier, the store's settle, motion idle and one commit) and reports the reply's `elapsed_ms` as p50, p95, p99
and max. It passes when every settle settled and the p99 is below --settle-max-ms.

It never launches or quits an app: start a tagged DEV build first, then point it at that build's control
socket (the fleet runs it through nx-remote on a GUI host):

  nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \\
    python3 scripts/cmux-next/bench-oracle-settle.py --socket SOCKET

Prints one JSON line with the distribution; exits 1 when a settle did not settle or the p99 is too high.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402


def percentile(sorted_values, fraction):
    """The nearest-rank percentile of an ascending list."""
    if not sorted_values:
        return None
    rank = max(1, math.ceil(fraction * len(sorted_values)))
    return sorted_values[min(rank, len(sorted_values)) - 1]


def run(client, count, settle_max_ms, sequence):
    elapsed, unsettled = [], []
    for index in range(count):
        reply = client.call("debug.oracle.settle", {"sequence": sequence, "settleMaxMs": settle_max_ms})
        result = reply.get("result")
        if result is None:
            raise SystemExit(f"bench-oracle-settle: settle {index} failed: {json.dumps(reply.get('error', reply))}")
        if not result.get("settled"):
            unsettled.append({"index": index, "pending": result.get("pending")})
        elapsed.append(float(result.get("elapsed_ms", 0)))
    return elapsed, unsettled


def summarize(elapsed, unsettled, settle_max_ms):
    ordered = sorted(elapsed)
    summary = {
        "count": len(ordered),
        "settle_max_ms": settle_max_ms,
        "p50_ms": percentile(ordered, 0.50),
        "p95_ms": percentile(ordered, 0.95),
        "p99_ms": percentile(ordered, 0.99),
        "max_ms": ordered[-1] if ordered else None,
        "unsettled": unsettled[:10],
        "unsettled_count": len(unsettled),
    }
    summary["pass"] = not unsettled and summary["p99_ms"] is not None and summary["p99_ms"] < settle_max_ms
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", required=True, help="the running DEV build's control socket")
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--settle-max-ms", type=int, default=5000)
    parser.add_argument("--sequence", default="sync", help='"sync" (default) or a home daemon event sequence')
    args = parser.parse_args(argv)
    sequence = int(args.sequence) if args.sequence.isdigit() else args.sequence
    client = Client(args.socket, timeout=args.settle_max_ms / 1000 + 5)
    try:
        elapsed, unsettled = run(client, args.count, args.settle_max_ms, sequence)
    finally:
        client.close()
    summary = summarize(elapsed, unsettled, args.settle_max_ms)
    print(json.dumps(summary))
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
