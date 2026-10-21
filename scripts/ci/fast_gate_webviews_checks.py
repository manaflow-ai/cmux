#!/usr/bin/env python3
"""The webviews checks gate of the cmux-next fast gates, run on a pull request merged with the current tip.

    fast_gate_webviews_checks.py [--repo PATH]

Installs webviews' node_modules (bun install --frozen-lockfile) and runs, in webviews/, each check that ci-web's
"Check webviews" step fails on for a feat-cmux-next pull request, except the type check, which compiles rather than
checks. Runs all of them and exits 1 when any fails. tests/test_cmux_next_fast_gates.py keeps CHECKS equal to
ci-web.yml's fail-mode list.

cmux_next_fast_gates.py runs this only on a dispatch (pr=N, against the current tip): on a pull_request event
ci-web already ran these checks on the same merge commit. A merger dispatches when a check path
(scripts/ci/check-paths.txt) changed on the base after the pull request's last fast-gates base, so a check that
landed after the pull request's CI runs on it before it merges (2026-10-21: #22967, #22975 and #23094 merged past
the new check:fixed-waits).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

CHECKS = ("check:browser-lanes", "check:fixed-waits", "acpmux-protocol:check", "check:catalog-keys")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    webviews = args.repo / "webviews"
    if subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=webviews).returncode != 0:
        print("webviews checks: bun install --frozen-lockfile failed", flush=True)
        return 1
    failed = [check for check in CHECKS if subprocess.run(["bun", "run", check], cwd=webviews).returncode != 0]
    for check in failed:
        print(f"::error title=webviews {check}::{check} failed on the pull request merged with the current tip")
    print(f"webviews checks: {', '.join(failed) + ' failed' if failed else 'all passed'}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
