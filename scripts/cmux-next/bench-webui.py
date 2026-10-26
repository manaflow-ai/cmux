#!/usr/bin/env python3
"""cmux page (WebUI) bench: one driver over the existing benches (plans/cmux-next/chrome-parity/p13-webui.md,
section 3.G and the D done checks). Agents run it on a fleet GUI mini against a tagged DEV build; no CI gate and
no budget rows.

Modes:
  priority  scheduling role, QoS and footprint per process kind while pages are parked, shown and hidden, the
            time a hidden page renderer takes to background, and the MemoryPurgeOnFreeze arm (D12, task 083;
            bench_webui_priority.py)

The other modes of task 002 (home, pages10, open, crash, pressure, delivery) join this dispatcher.

Usage:
  bench-webui.py priority --app BUNDLE [--engine chromium|webkit|both] [--pages settings,history] [--runs 5]
      [--purge-arm] [--out FILE.json]
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_webui_priority  # noqa: E402

MODES = {"priority": bench_webui_priority}


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = top.add_subparsers(dest="mode", required=True)
    for name, module in MODES.items():
        module.add_arguments(modes.add_parser(name, help=module.__doc__.splitlines()[0]))
    return top


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    return MODES[args.mode].main(args)


if __name__ == "__main__":
    sys.exit(main())
