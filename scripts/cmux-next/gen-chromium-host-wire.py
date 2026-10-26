#!/usr/bin/env python3
"""Chromium Host wire generator and its checks (plans/cmux-next/chrome-parity/p01-process.md, 3.2).

  --check-view-parity   every method of the vendored remote_cocoa mojoms
                        (plans/cmux-next/remote_cocoa_mojom/) maps to an op or
                        an event, or has a written not-needed reason, in
                        plans/cmux-next/chromium-host-view-parity.json; exits 1
                        on an unmapped method, a stale row, a name that does
                        not exist, a [Sync] method not answered from pushed
                        state, or mojom drift (sha256).
  --list-unmapped       with the check, print the Q5 queue: unmapped methods
                        and rows that wait on a planned wire kind or export,
                        with the task that adds it.

Portable: no build, no CEF. The view-parity logic and its flags live in
chromium_host_view_parity.py; task p01-process-011 adds the shim generator's
--check, --list-missing, --swift-sites and --check-return-use modes to this
parser beside them.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import chromium_host_view_parity as view_parity

REPO = Path(__file__).resolve().parents[2]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=REPO, help="repository root (fixtures use a copy)")
    view_parity.add_arguments(parser)
    args = parser.parse_args(argv)
    if view_parity.wants_run(args):
        return view_parity.run(args)
    parser.error("name a check: --check-view-parity")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
