#!/usr/bin/env python3
"""Before/after of the infinite-chats ladder: two chat-size-sweep.sh logs, one table.

Reads the `CHAT-SIZE {...}` lines (one per size) and the `infinite_chat_size_ratio_max` line from a base run and a
head run of scripts/measure/chat-size-sweep.sh, and prints a Markdown table: each metric at each size, its ratio of
the largest size to the first (the goal's axis: 1.2x or under), for base and head, and the change in that ratio.

Leo, 2026-11-19: "we need to be able to have infinite chats, infinitely long chats, that sort of thing on, you know,
current day hardware".

    python3 scripts/measure/chat-size-compare.py BASE/run.out HEAD/run.out [--base-sha S] [--head-sha S]
"""
from __future__ import annotations

import argparse
import json
import sys

# (label, path into a CHAT-SIZE result, unit): the goal's headline axes first.
METRICS = [
    ("rssIdle", ("rssIdle",), "MB"),
    ("rssIdleAnon", ("rssIdleAnon",), "MB"),
    ("restartPeakRss", ("restartPeakRss",), "MB"),
    ("peakRss", ("peakRss",), "MB"),
    ("promptPage p50", ("promptPageUs", "p50"), "us"),
    ("sendFirstToken p50", ("sendFirstTokenUs", "p50"), "us"),
    ("scrollDeep p50", ("scrollDeepUs", "p50"), "us"),
    ("attach p50", ("attachUs", "p50"), "us"),
    ("restartSendFirstToken", ("restartSendFirstTokenUs",), "us"),
]


def read(path: str) -> tuple[dict[str, dict], str | None]:
    sizes: dict[str, dict] = {}
    worst = None
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return sizes, None
    for line in lines:
        if line.startswith("CHAT-SIZE {"):
            try:
                result = json.loads(line[len("CHAT-SIZE "):])
            except ValueError:
                continue
            sizes[str(result.get("size"))] = result
        elif line.startswith("infinite_chat_size_ratio_max "):
            worst = " ".join(line.split()[1:])
    return sizes, worst


def value(result: dict | None, path: tuple[str, ...]) -> float | None:
    v = result
    for key in path:
        if not isinstance(v, dict):
            return None
        v = v.get(key)
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def fmt(v: float | None, unit: str) -> str:
    if v is None:
        return "-"
    return f"{v / 1e6:.1f}" if unit == "MB" else f"{v:.0f}"


def ratio(sizes: dict[str, dict], order: list[str], path: tuple[str, ...]) -> float | None:
    if len(order) < 2:
        return None
    first, last = value(sizes.get(order[0]), path), value(sizes.get(order[-1]), path)
    return last / first if first and last is not None else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("head")
    ap.add_argument("--base-sha", default="")
    ap.add_argument("--head-sha", default="")
    args = ap.parse_args()
    base, base_worst = read(args.base)
    head, head_worst = read(args.head)
    order = list(head) or list(base)
    for s in base:
        if s not in order:
            order.append(s)
    if not order:
        print("chat-size-compare: no CHAT-SIZE lines in either run", file=sys.stderr)
        return 1
    big, small = order[-1], order[0]
    out = [
        f"### Chat-size ladder: base {args.base_sha[:10] or '?'} vs head {args.head_sha[:10] or '?'}",
        "",
        f"Worst {big}/{small} ratio (goal: 1.2x or under): base **{base_worst or 'none'}**, "
        f"head **{head_worst or 'none'}**.",
        "",
        "| Metric | unit | " + " | ".join(f"base {s}" for s in order) + f" | base {big}/{small} | "
        + " | ".join(f"head {s}" for s in order) + f" | head {big}/{small} | change |",
        "|---|---|" + "---|" * (2 * len(order) + 3),
    ]
    for label, path, unit in METRICS:
        rb, rh = ratio(base, order, path), ratio(head, order, path)
        change = f"{rh - rb:+.2f}" if rb is not None and rh is not None else "-"
        out.append(
            f"| {label} | {unit} | "
            + " | ".join(fmt(value(base.get(s), path), unit) for s in order)
            + f" | {f'{rb:.2f}' if rb is not None else '-'} | "
            + " | ".join(fmt(value(head.get(s), path), unit) for s in order)
            + f" | {f'{rh:.2f}' if rh is not None else '-'} | {change} |"
        )
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
