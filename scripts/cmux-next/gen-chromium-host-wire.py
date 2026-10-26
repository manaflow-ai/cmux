#!/usr/bin/env python3
"""Chromium Host wire generator and its checks (plans/cmux-next/chrome-parity/p01-process.md, 3.2).

  --check-view-parity   every method of the vendored remote_cocoa mojoms
                        (plans/cmux-next/remote_cocoa_mojom/) maps to an op, an
                        event, cmux handling or a written not-needed reason in
                        plans/cmux-next/chromium-host-view-parity.json; exits 1
                        on an unmapped method, a stale row, a name that does
                        not exist, a [Sync] method not answered from pushed
                        state, or mojom drift (sha256).
  --list-unmapped       with the check, print the Q5 queue: unmapped methods
                        and rows that wait on a planned wire kind, with the
                        task that adds it.

Portable: no build, no CEF. Task p01-process-011 adds the shim generator and
its --check, --list-missing, --swift-sites and --check-return-use modes here.
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
    parser.add_argument("--check-view-parity", action="store_true")
    parser.add_argument("--list-unmapped", action="store_true", help="print the remote_cocoa parity queue")
    parser.add_argument("--parity", default=view_parity.PARITY_JSON, help="parity JSON, relative to --repo")
    args = parser.parse_args(argv)
    if not (args.check_view_parity or args.list_unmapped):
        parser.error("name a check: --check-view-parity")

    try:
        report = view_parity.check(args.repo, args.parity)
    except view_parity.ParityError as error:
        print(f"gen-chromium-host-wire: {error}", file=sys.stderr)
        return 2
    if args.list_unmapped:
        for line in view_parity.unmapped_lines(report):
            print(line)
    for error in report.errors:
        print(f"view parity: {error}", file=sys.stderr)
    print(view_parity.summary(report), file=sys.stderr if args.list_unmapped else sys.stdout)
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
