#!/usr/bin/env python3
"""A job-time apt install of a cmux-tui build dependency skips apt when the runner already has it.

The org's Linux runner images bake clang, libclang-dev and pkg-config (and the other job packages:
valgrind, xvfb, musl-tools and more). A step that runs `apt-get update` and `apt-get install` anyway
pays for the package lists, apt's update hooks and, where the image lacks one, the download: on
2026-11-26 the "Install Linux cmux-tui build dependencies" step of a cloud-move-kill run spent
18.5 min after `apt-get update` (5.9 MB of lists at 164 kB/s, then the update hooks) and was
cancelled before it installed anything, and libclang-dev alone is 28.8 MB on a link that slow.

So every `run:` that installs libclang-dev with apt first asks dpkg (`dpkg -s PKG...`, which exits
non-zero when any is missing) and runs apt only then.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
INSTALL = re.compile(r"apt-get\s+install\b[^\n]*\blibclang-dev\b")


def unguarded(text: str) -> list[str]:
    """Where a `run:` in one workflow's text installs libclang-dev with no dpkg -s check first."""
    doc = yaml.safe_load(text) or {}
    found = []
    for job_name, job in (doc.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            run = (step or {}).get("run") or ""
            for match in INSTALL.finditer(run):
                if "dpkg -s " not in run[: match.start()]:
                    found.append(f"{job_name}: {step.get('name') or run.splitlines()[0]}")
    return found


class AptSkipsBakedPackagesTest(unittest.TestCase):
    def test_every_libclang_install_asks_dpkg_first(self) -> None:
        offenders = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            offenders += [f"{path.name}: {where}" for where in unguarded(path.read_text())]
        self.assertEqual(offenders, [], "guard each with `if dpkg -s PKG... >/dev/null 2>&1; then ...; else apt; fi`")

    def test_the_check_catches_a_bare_install(self) -> None:
        bare = "jobs:\n  j:\n    steps:\n      - run: |\n          sudo apt-get update\n          sudo apt-get install -y clang libclang-dev pkg-config\n"
        guarded = bare.replace("sudo apt-get update", "dpkg -s clang libclang-dev pkg-config || sudo apt-get update")
        self.assertEqual(unguarded(bare), ["j: sudo apt-get update"])
        self.assertEqual(unguarded(guarded), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
