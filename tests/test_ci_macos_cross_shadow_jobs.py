#!/usr/bin/env python3
"""The macOS cross-compile shadow jobs stay compare-only.

MACOS-CROSS-COMPILE-ON-LINUX builds macOS artifacts on Linux beside the Mac
builds and compares them (scripts/ci/macos-cross.sh). Until the comparison has
been clean for three publishes, a shadow job must never change a publication:
no other job may need it, a red comparison must not fail the run, and it holds
no write permission and no secret.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SHADOWS = [
    # (workflow file, shadow job id, the job whose output it compares)
    ("cmux-tui-artifacts.yml", "macos-cross-shadow", "publish"),
    # The x86_64 run-time half runs the shadow job's binaries on an Intel Mac.
    ("cmux-tui-artifacts.yml", "macos-cross-runtime-x86_64", "macos-cross-shadow"),
    ("app-ffi-release.yml", "macos-cross-shadow", "build"),
]
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", re.M)


def jobs(text: str) -> dict[str, str]:
    """Job id -> its block, from the top-level `jobs:` mapping."""
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    headers = list(JOB_HEADER.finditer(body))
    return {m.group(1): body[m.start():headers[i + 1].start() if i + 1 < len(headers) else len(body)]
            for i, m in enumerate(headers)}


def needs(block: str) -> set[str]:
    m = re.search(r"^    needs:\s*(.+)$", block, re.M)
    if not m:
        return set()
    return {n.strip() for n in m.group(1).strip("[] ").split(",") if n.strip()}


class ShadowJobTests(unittest.TestCase):
    def test_every_shadow_job_is_compare_only(self) -> None:
        for workflow, shadow, compared in SHADOWS:
            with self.subTest(workflow=workflow, shadow=shadow):
                all_jobs = jobs((WORKFLOWS / workflow).read_text(encoding="utf-8"))
                self.assertIn(shadow, all_jobs, f"{workflow} has no {shadow} job")
                block = all_jobs[shadow]
                self.assertIn(compared, needs(block), f"{workflow}:{shadow} must run after {compared}")
                self.assertRegex(block, r"(?m)^    continue-on-error: true$")
                permissions = re.search(r"(?m)^    permissions:\n((?:      [a-z-]+: [a-z]+\n)+)", block)
                self.assertIsNotNone(permissions, f"{workflow}:{shadow} must declare its permissions")
                self.assertEqual(permissions.group(1).split(), ["contents:", "read"])
                self.assertNotIn("secrets.", block)
                self.assertNotRegex(block, r"(?m)^    environment:")
                # Only another compare-only shadow job may need a shadow job.
                shadows = {job for wf, job, _ in SHADOWS if wf == workflow}
                dependents = sorted(job for job, other in all_jobs.items()
                                    if shadow in needs(other) and job not in shadows)
                self.assertEqual(dependents, [], f"{workflow}: {dependents} must not need {shadow}")

    def test_shadow_jobs_run_the_shared_script(self) -> None:
        for workflow, shadow, compared in SHADOWS:
            if compared not in {"publish", "build"}:
                continue  # the run-time half builds nothing
            with self.subTest(workflow=workflow):
                block = jobs((WORKFLOWS / workflow).read_text(encoding="utf-8"))[shadow]
                self.assertIn("scripts/ci/macos-cross.sh", block)
                self.assertIn("python3 tests/test_ci_macho_parity.py", block)
                # The sysroot is Zig's darwin stub: it must be the Zig the
                # ghostty-next manifest sets (pin run 37589232394 got another).
                self.assertRegex(block, r"GHOSTTY_ZIG_SOURCE: ghostty-next\n(?:.*\n){0,4}.*ghostty-zig-version\.sh")


if __name__ == "__main__":
    unittest.main()
