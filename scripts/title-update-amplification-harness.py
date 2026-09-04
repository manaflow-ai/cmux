#!/usr/bin/env python3
"""Deterministically model the OSC-title amplification stages.

This is a rate/count harness, not a WindowServer simulator. It mirrors the
one-shot coalescing contracts in the app so a review can reproduce the source
rate, main-actor notification count, workspace publishes, and window writes
without launching AppKit or mutating the user's desktop.
"""

from __future__ import annotations

import argparse
import heapq
import json
from dataclasses import dataclass


@dataclass(frozen=True)
class HarnessConfig:
    duration_ms: int
    surfaces: int
    source_hz: int
    ingress_ms: int
    panel_ms: int
    window_ms: int


@dataclass
class HarnessResult:
    config: HarnessConfig
    source_updates: int
    ingress_publishes: int
    workspace_publishes: int
    window_writes: int
    synthetic_main_work_ms: float
    peak_one_second_work_ms: float


def simulate(config: HarnessConfig) -> HarnessResult:
    source_period_ms = max(1, round(1_000 / config.source_hz))
    queue: list[tuple[int, int, str, int | None]] = []
    sequence = 0

    def enqueue(at_ms: int, kind: str, surface: int | None) -> None:
        nonlocal sequence
        sequence += 1
        heapq.heappush(queue, (at_ms, sequence, kind, surface))

    for at_ms in range(0, config.duration_ms, source_period_ms):
        for surface in range(config.surfaces):
            enqueue(at_ms, "source", surface)

    ingress_due: list[int | None] = [None] * config.surfaces
    ingress_latest: list[int | None] = [None] * config.surfaces
    panel_due: int | None = None
    panel_latest: dict[int, int] = {}
    window_due: int | None = None
    window_latest: int | None = None
    last_window_title: int | None = None

    source_updates = 0
    ingress_publishes = 0
    workspace_publishes = 0
    window_writes = 0
    work_by_second: dict[int, float] = {}

    def account(at_ms: int, amount: float) -> None:
        bucket = at_ms // 1_000
        work_by_second[bucket] = work_by_second.get(bucket, 0.0) + amount

    while queue:
        at_ms, _, kind, surface = heapq.heappop(queue)

        if kind == "source":
            assert surface is not None
            source_updates += 1
            ingress_latest[surface] = source_updates
            if ingress_due[surface] is None:
                due = at_ms + config.ingress_ms
                ingress_due[surface] = due
                enqueue(due, "ingress", surface)
            continue

        if kind == "ingress":
            assert surface is not None
            if ingress_due[surface] != at_ms:
                continue
            ingress_due[surface] = None
            title = ingress_latest[surface]
            if title is None:
                continue
            ingress_publishes += 1
            account(at_ms, 0.05)
            panel_latest[surface] = title
            if panel_due is None:
                panel_due = at_ms + config.panel_ms
                enqueue(panel_due, "panel", None)
            continue

        if kind == "panel":
            if panel_due != at_ms:
                continue
            panel_due = None
            updates = panel_latest
            panel_latest = {}
            workspace_publishes += len(updates)
            account(at_ms, 0.50 * len(updates))
            # A selected workspace/window is represented by surface zero.
            if 0 in updates:
                window_latest = updates[0]
                if config.window_ms == 0:
                    if window_latest != last_window_title:
                        window_writes += 1
                        last_window_title = window_latest
                        account(at_ms, 0.20)
                    window_latest = None
                elif window_due is None:
                    window_due = at_ms + config.window_ms
                    enqueue(window_due, "window", None)
            continue

        if kind == "window":
            if window_due != at_ms:
                continue
            window_due = None
            if window_latest is not None and window_latest != last_window_title:
                window_writes += 1
                last_window_title = window_latest
                account(at_ms, 0.20)
            window_latest = None

    total_work = sum(work_by_second.values())
    return HarnessResult(
        config=config,
        source_updates=source_updates,
        ingress_publishes=ingress_publishes,
        workspace_publishes=workspace_publishes,
        window_writes=window_writes,
        synthetic_main_work_ms=round(total_work, 2),
        peak_one_second_work_ms=round(max(work_by_second.values(), default=0.0), 2),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--duration-seconds", type=int, default=5)
    parser.add_argument("--surfaces", type=int, default=5)
    parser.add_argument("--source-hz", type=int, default=20)
    parser.add_argument("--ingress-ms", type=int, required=True)
    parser.add_argument("--panel-ms", type=int, required=True)
    parser.add_argument("--window-ms", type=int, required=True)
    args = parser.parse_args()
    if args.duration_seconds < 0 or args.surfaces < 1 or args.source_hz < 1:
        parser.error(
            "--duration-seconds must be non-negative; "
            "--surfaces and --source-hz must be positive"
        )
    if min(args.ingress_ms, args.panel_ms, args.window_ms) < 0:
        parser.error("coalescing intervals must be non-negative")

    result = simulate(HarnessConfig(
        duration_ms=args.duration_seconds * 1_000,
        surfaces=args.surfaces,
        source_hz=args.source_hz,
        ingress_ms=args.ingress_ms,
        panel_ms=args.panel_ms,
        window_ms=args.window_ms,
    ))
    payload = {
        "label": args.label,
        "source_updates": result.source_updates,
        "ingress_publishes": result.ingress_publishes,
        "workspace_publishes": result.workspace_publishes,
        "window_writes": result.window_writes,
        "synthetic_main_work_ms": result.synthetic_main_work_ms,
        "peak_one_second_work_ms": result.peak_one_second_work_ms,
        "config": result.config.__dict__,
    }
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    main()
