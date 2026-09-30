#!/usr/bin/env python3
"""Report feature flags whose review dates are approaching."""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
LINTER = REPO / "scripts" / "lint-feature-flags.py"
LEAD_TIME_DAYS = 30


def _load_linter():
    spec = importlib.util.spec_from_file_location("lint_feature_flags", LINTER)
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load {LINTER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_report(
    flags: list[dict[str, Any]],
    today: datetime.date | None = None,
) -> list[dict[str, Any]]:
    """Return flags due within the lead time, ordered by date and key."""
    today = today or datetime.date.today()
    report: list[dict[str, Any]] = []
    for flag in flags:
        review = flag.get("reviewBy")
        try:
            review_date = datetime.date.fromisoformat(review)
        except (TypeError, ValueError):
            continue
        days_remaining = (review_date - today).days
        if 0 <= days_remaining <= LEAD_TIME_DAYS:
            report.append({
                "key": flag.get("key"),
                "source": flag.get("source"),
                "reviewBy": review,
                "daysRemaining": days_remaining,
            })
    return sorted(report, key=lambda item: (item["daysRemaining"], item["key"], item["source"]))


def render_report(report: list[dict[str, Any]], as_json: bool = False) -> str:
    if as_json:
        return json.dumps(report, indent=2, sort_keys=True)
    if not report:
        return "No feature flag review dates are within 30 days."
    headers = ("key", "source file", "reviewBy", "days remaining")
    rows = [
        (item["key"], item["source"], item["reviewBy"], str(item["daysRemaining"]))
        for item in report
    ]
    widths = [max(len(headers[index]), *(len(row[index]) for row in rows)) for index in range(4)]
    line = "  ".join(headers[index].ljust(widths[index]) for index in range(4))
    separator = "  ".join("-" * width for width in widths)
    body = ["  ".join(row[index].ljust(widths[index]) for index in range(4)) for row in rows]
    return "\n".join([line, separator, *body])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    args = parser.parse_args(argv)
    try:
        flags = _load_linter().collect_flags()
        report = build_report(flags)
        print(render_report(report, as_json=args.json))
    except Exception as error:  # The report must never fail a build.
        if args.json:
            print("[]")
        else:
            print(f"Feature flag review report unavailable: {error}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
