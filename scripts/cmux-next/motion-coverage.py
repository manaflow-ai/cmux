#!/usr/bin/env python3
"""The animation-token coverage of cmux NEXT, as JSON for the nightly (scripts/cmux-next/motion_inventory.py).

    scripts/cmux-next/motion-coverage.py [--root DIR] [--sites] [--min-coverage F] [--max-slow N]

Prints {"coverage": tokened / all animations, "surfaces": {surface: {animations, tokened, coverage, loops, allowed,
slow, token_defs, token_defs_slow}}, "slow": [...]}: an animation is tokened when its duration comes from the shared
motion tokens (schemas/motion-scale/motion-scale.json, MotionTunables); slow is a state change longer than 200 ms.
--sites adds every site. Exits 0, or 1 when --min-coverage or --max-slow is given and missed, so a nightly can
track the figure first and gate on it later.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_inventory as mi  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=mi.REPO)
    parser.add_argument("--sites", action="store_true", help="list every animation site too")
    parser.add_argument("--min-coverage", type=float, help="exit 1 when the overall coverage is under this (0-1)")
    parser.add_argument("--max-slow", type=int, help="exit 1 when more animations than this are slow")
    args = parser.parse_args()
    inv = mi.inventory(args.root.resolve())
    report = mi.coverage(inv)
    if args.sites:
        report["sites"] = mi.as_json(inv.sites)
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    failed = (args.min_coverage is not None and (report["coverage"] or 0) < args.min_coverage) or (
        args.max_slow is not None and sum(1 for s in report["slow"] if s["kind"] == "site") > args.max_slow)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
