#!/usr/bin/env python3
"""Validate receipts emitted by the cmux-next sidebar performance harnesses.

The GUI harnesses run on an enrolled Mac and write JSON; this script is deliberately
portable so the same artifact can be checked by CI or a reviewer. It never launches an
app and never treats a missing optional frame metric as zero.

Examples:

    python3 scripts/cmux-next/sidebar-perf-validate.py artifacts/sidebar
    python3 scripts/cmux-next/sidebar-perf-validate.py artifacts/sidebar \
        --require-counters --max-main-us-per-tick 250 \
        --max-scroll-configures-per-realize 4 \
        --max-frame-p95-ms 16.7 --max-frame-p99-ms 25 \
        --max-hitch-p95-ms 16.7 --max-hitch-p99-ms 25

The default structural budgets are zero rebuilds and zero list reloads. Optional
work and frame budgets are explicit because their absolute values depend on the
enrolled display and host floor; an absent optional metric remains unknown.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator


@dataclass(frozen=True)
class Budgets:
    rebuilds: int = 0
    list_reloads: int = 0
    max_frame_p99_ms: float | None = None
    max_frame_max_ms: float | None = None
    max_hitch_total_ms: float | None = None
    max_hitch_max_ms: float | None = None
    require_counters: bool = False
    max_main_us_per_tick: float | None = None
    max_scroll_row_configures: int | None = None
    max_scroll_configures_per_realize: float | None = None
    max_frame_p95_ms: float | None = None
    max_hitch_p95_ms: float | None = None
    max_hitch_p99_ms: float | None = None


def receipt_kind(path: Path) -> str | None:
    name = path.name
    if name.startswith("summary-") and name.endswith(".json"):
        return "live"
    if name.startswith("release-") and name.endswith(".json"):
        return "release"
    if name.startswith("mirror-rebuild-") and name.endswith(".json"):
        return "mirror"
    return None


def discover(root: Path) -> list[tuple[Path, str]]:
    if root.is_file():
        kind = receipt_kind(root)
        return [(root, kind)] if kind else []
    return sorted(
        (path, kind)
        for path in root.rglob("*.json")
        if (kind := receipt_kind(path)) is not None
    )


def walk(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def walk_with_path(value: Any, path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], dict[str, Any]]]:
    """Yield objects with their receipt path so phase-specific budgets stay scoped."""
    if isinstance(value, dict):
        yield path, value
        for key, child in value.items():
            yield from walk_with_path(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_with_path(child, path + (str(index),))


def number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(float(value)) else None


def validate_counters(receipt: dict[str, Any], budgets: Budgets) -> list[str]:
    errors: list[str] = []
    counters = [
        (path, item["counters"])
        for path, item in walk_with_path(receipt)
        if isinstance(item.get("counters"), dict)
    ]
    if not counters:
        if budgets.require_counters:
            errors.append("missing counters (use a candidate build that serves debug.sidebar_perf)")
        return errors
    required = ("rebuilds", "list_reloads", "row_patches", "row_configures")
    for index, (path, current) in enumerate(counters):
        prefix = f"counters[{index}]"
        missing = [key for key in required if number(current.get(key)) is None]
        if missing:
            errors.append(f"{prefix} missing numeric fields: {', '.join(missing)}")
            continue
        if current["rebuilds"] > budgets.rebuilds:
            errors.append(f"{prefix}.rebuilds={current['rebuilds']} > {budgets.rebuilds}")
        if current["list_reloads"] > budgets.list_reloads:
            errors.append(f"{prefix}.list_reloads={current['list_reloads']} > {budgets.list_reloads}")
        is_scroll = any("scroll" in part.casefold() for part in path)
        # A realize pass configures newly visible rows without a row patch. Keep the
        # old patch/configure invariant for tick and mutation phases, and use the
        # explicit scroll budgets below for realization churn.
        if not is_scroll and current["row_configures"] > current["row_patches"]:
            errors.append(
                f"{prefix}.row_configures={current['row_configures']} > row_patches={current['row_patches']}"
            )
        if is_scroll:
            configures = number(current.get("row_configures"))
            if (
                budgets.max_scroll_row_configures is not None
                and configures is not None
                and configures > budgets.max_scroll_row_configures
            ):
                errors.append(
                    f"{prefix}.row_configures={configures:g} > {budgets.max_scroll_row_configures} during scroll"
                )
            realizes = number(current.get("scroll_realizes"))
            if (
                budgets.max_scroll_configures_per_realize is not None
                and configures is not None
                and realizes is not None
                and realizes > 0
                and configures / realizes > budgets.max_scroll_configures_per_realize
            ):
                ratio = configures / realizes
                errors.append(
                    f"{prefix}.row_configures/scroll_realizes={ratio:g} > "
                    f"{budgets.max_scroll_configures_per_realize:g} during scroll"
                )
    return errors


def validate_tick_metrics(receipt: dict[str, Any], budgets: Budgets) -> list[str]:
    if budgets.max_main_us_per_tick is None:
        return []
    errors: list[str] = []
    for path, item in walk_with_path(receipt):
        value = number(item.get("main_us_per_tick"))
        if value is not None and value > budgets.max_main_us_per_tick:
            label = ".".join(path) or "receipt"
            errors.append(f"{label}.main_us_per_tick={value:g} > {budgets.max_main_us_per_tick:g} us")
    return errors


def validate_frame_metrics(receipt: dict[str, Any], budgets: Budgets) -> list[str]:
    errors: list[str] = []
    for item in walk(receipt):
        frames = item.get("frames")
        if isinstance(frames, dict):
            for key, limit in (
                ("p95_ms", budgets.max_frame_p95_ms),
                ("p99_ms", budgets.max_frame_p99_ms),
                ("max_ms", budgets.max_frame_max_ms),
            ):
                value = number(frames.get(key))
                if limit is not None and value is not None and value > limit:
                    errors.append(f"frames.{key}={value:g} > {limit:g} ms")
        hitches = item.get("hitches")
        if isinstance(hitches, dict):
            for key, limit in (
                ("p95_ms", budgets.max_hitch_p95_ms),
                ("p99_ms", budgets.max_hitch_p99_ms),
                ("total_ms", budgets.max_hitch_total_ms),
                ("max_ms", budgets.max_hitch_max_ms),
            ):
                value = number(hitches.get(key))
                if limit is not None and value is not None and value > limit:
                    errors.append(f"hitches.{key}={value:g} > {limit:g} ms")
    return errors


def validate_mirror(receipt: dict[str, Any]) -> list[str]:
    required = ("view_calls", "rebuilds", "mirror_ms_total", "main_ms_total")
    errors = [f"missing numeric field: {key}" for key in required if number(receipt.get(key)) is None]
    if errors:
        return errors
    if receipt["view_calls"] <= 0:
        errors.append("view_calls must be greater than zero")
    if receipt["rebuilds"] <= 0:
        errors.append("rebuilds must be greater than zero")
    return errors


def validate(path: Path, kind: str, budgets: Budgets) -> list[str]:
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot read JSON: {error}"]
    if not isinstance(receipt, dict):
        return ["receipt root must be an object"]
    errors: list[str] = []
    failures = receipt.get("failures")
    if isinstance(failures, list) and failures:
        errors.append(f"harness failures: {len(failures)}")
    if kind == "mirror":
        errors.extend(validate_mirror(receipt))
    else:
        errors.extend(validate_counters(receipt, budgets))
    errors.extend(validate_tick_metrics(receipt, budgets))
    errors.extend(validate_frame_metrics(receipt, budgets))
    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="receipt file or directory")
    parser.add_argument("--max-main-us-per-tick", type=float)
    parser.add_argument("--max-scroll-row-configures", type=int)
    parser.add_argument("--max-scroll-configures-per-realize", type=float)
    parser.add_argument("--max-frame-p95-ms", type=float)
    parser.add_argument("--max-frame-p99-ms", type=float)
    parser.add_argument("--max-frame-max-ms", type=float)
    parser.add_argument("--max-hitch-p95-ms", type=float)
    parser.add_argument("--max-hitch-p99-ms", type=float)
    parser.add_argument("--max-hitch-total-ms", type=float)
    parser.add_argument("--max-hitch-max-ms", type=float)
    parser.add_argument("--rebuilds", type=int, default=0)
    parser.add_argument("--list-reloads", type=int, default=0)
    parser.add_argument("--require-counters", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    non_negative = (
        args.rebuilds,
        args.list_reloads,
        args.max_main_us_per_tick,
        args.max_scroll_row_configures,
        args.max_scroll_configures_per_realize,
        args.max_frame_p95_ms,
        args.max_frame_p99_ms,
        args.max_frame_max_ms,
        args.max_hitch_p95_ms,
        args.max_hitch_p99_ms,
        args.max_hitch_total_ms,
        args.max_hitch_max_ms,
    )
    if any(value is not None and (not math.isfinite(float(value)) or value < 0) for value in non_negative):
        print("budgets must be non-negative", file=sys.stderr)
        return 2
    budgets = Budgets(
        rebuilds=args.rebuilds,
        list_reloads=args.list_reloads,
        max_main_us_per_tick=args.max_main_us_per_tick,
        max_scroll_row_configures=args.max_scroll_row_configures,
        max_scroll_configures_per_realize=args.max_scroll_configures_per_realize,
        max_frame_p95_ms=args.max_frame_p95_ms,
        max_frame_p99_ms=args.max_frame_p99_ms,
        max_frame_max_ms=args.max_frame_max_ms,
        max_hitch_p95_ms=args.max_hitch_p95_ms,
        max_hitch_p99_ms=args.max_hitch_p99_ms,
        max_hitch_total_ms=args.max_hitch_total_ms,
        max_hitch_max_ms=args.max_hitch_max_ms,
        require_counters=args.require_counters,
    )
    receipts = discover(args.root)
    if not receipts:
        print(f"no sidebar receipts found under {args.root}", file=sys.stderr)
        return 2
    failed = False
    for path, kind in receipts:
        errors = validate(path, kind, budgets)
        if errors:
            failed = True
            print(f"FAIL {path} ({kind}):")
            for error in errors:
                print(f"  - {error}")
        else:
            print(f"PASS {path} ({kind})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
