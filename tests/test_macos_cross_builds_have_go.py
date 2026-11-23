#!/usr/bin/env python3
"""Every job that cross-builds the cmux-tui binaries for macOS on Linux installs the Go that
cmux-tailnet's build.rs needs for libtailscale.

macos-cross-parity.yml's dispatch at 57ecf374 (run 44976549408, 2026-11-22) stopped in
cmux-tailnet's build script ("`go` was not found") before any link, so it said nothing about the
binaries it exists to compare. cmux-tui-build-package.yml and cmux-tui.yml already install it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
GO_VERSION_FILE = "cmux-tui/crates/cmux-tailnet/go-version"


def cross_bins_jobs():
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (workflow.get("jobs") or {}).items():
            steps = job.get("steps") or []
            runs = [str(step.get("run", "")) for step in steps]
            if any("macos-cross.sh bins" in run or "macos-cross.sh all" in run for run in runs):
                yield path.name, name, steps


class MacosCrossBuildsHaveGo(unittest.TestCase):
    def test_each_cross_bins_job_installs_go_from_the_tailnet_version_file(self):
        jobs = list(cross_bins_jobs())
        self.assertTrue(any(file == "macos-cross-parity.yml" for file, _, _ in jobs), jobs)
        for file, name, steps in jobs:
            build = next(i for i, step in enumerate(steps)
                         if "macos-cross.sh bins" in str(step.get("run", ""))
                         or "macos-cross.sh all" in str(step.get("run", "")))
            go = [i for i, step in enumerate(steps)
                  if str(step.get("uses", "")).startswith("actions/setup-go@")
                  and (step.get("with") or {}).get("go-version-file") == GO_VERSION_FILE]
            self.assertTrue(go and go[0] < build,
                            f"{file} job {name}: install Go from {GO_VERSION_FILE} (actions/setup-go) "
                            "before macos-cross.sh builds the binaries")


if __name__ == "__main__":
    unittest.main()
