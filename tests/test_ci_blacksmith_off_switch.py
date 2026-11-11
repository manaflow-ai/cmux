#!/usr/bin/env python3
"""CI_BLACKSMITH_OFF=1 keeps every job off Blacksmith; unset, every job routes exactly as before.

Leo, 2026-11-10: "just stop using blacksmith temporarily". scripts/ci/blacksmith_off.py wraps each runs-on that
can reach a `blacksmith-*` label as

    ${{ vars.CI_BLACKSMITH_OFF == '1' && contains(toJSON(<original>), '"blacksmith-') && <off route> || (<original>) }}

Unset, the first term is false and the job takes <original>, the expression it had before, byte for byte. This test
reads every job of every workflow and proves the wrapper is on every runs-on that can reach Blacksmith, that the
original is intact in it, that the off route names only the GCP fleet, an owned Mac or GitHub-hosted labels (forks
only hosted), and that Blacksmith-only steps (sticky disks, Testbox) and the overflow probe are skipped while it is on.
feat-cmux-next's copy of this test also evaluates each expression (tests/runs_on_labels.py).
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import blacksmith_off  # noqa: E402

MAX_EXPRESSION = 21000
LABEL = re.compile(r"'([A-Za-z0-9._-]+)'")


def jobs():
    for path in blacksmith_off.workflow_files(ROOT):
        document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{path.name}#{name}", job


def not_wrapped(key: str) -> bool:
    """A workflow another guard pins (blacksmith_off.NOT_WRAPPED): it keeps its own selector."""
    return key.split("#", 1)[0] in blacksmith_off.NOT_WRAPPED


def skipped_when_off(condition) -> bool:
    return blacksmith_off.SKIP_WHEN_OFF in str(condition or "")


class BlacksmithOffSwitch(unittest.TestCase):
    def test_not_wrapped_workflows_name_their_guard(self):
        for name, reason in blacksmith_off.NOT_WRAPPED.items():
            with self.subTest(workflow=name):
                self.assertTrue((ROOT / ".github/workflows" / name).is_file(), "a stale entry")
                self.assertIn("scripts/", reason)

    def test_every_runs_on_that_can_reach_blacksmith_is_wrapped(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/blacksmith_off.py"), "--check"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrapped_runs_on_keeps_its_original_and_routes_off_blacksmith(self):
        allowed = {blacksmith_off.GCP_FLEET_LINUX, blacksmith_off.HOSTED_LINUX, blacksmith_off.HOSTED_LINUX_ARM,
                   blacksmith_off.HOSTED_WINDOWS, blacksmith_off.HOSTED_MACOS_15, blacksmith_off.HOSTED_MACOS_26}
        for key, job in jobs():
            runs_on = job.get("runs-on")
            if not isinstance(runs_on, str) or not blacksmith_off.is_wrapped(runs_on):
                continue
            with self.subTest(job=key):
                self.assertLess(len(runs_on), MAX_EXPRESSION)
                match = blacksmith_off.WRAPPED.match(runs_on.strip())
                original = match.group("orig")
                # The off route, with the original's own copies (toJSON(<original>) probes) taken out.
                route = match.group("off").replace(original, "")
                for label in LABEL.findall(route):
                    if label.startswith("-") or label.startswith('"'):
                        continue  # a contains() probe: '-macos-', '-windows-', '-arm"'
                    self.assertTrue(label in allowed or label.startswith("glaeda-"), label)
                    self.assertFalse(label.startswith("blacksmith-"), label)
                # A fork's pull request event takes only GitHub-hosted labels.
                for fork in re.findall(re.escape(blacksmith_off.FORK) + r" && '([A-Za-z0-9._-]+)'", route):
                    self.assertIn(fork, {blacksmith_off.HOSTED_LINUX, blacksmith_off.HOSTED_MACOS_15,
                                         blacksmith_off.HOSTED_MACOS_26})

    def test_blacksmith_only_steps_and_jobs_are_skipped_when_set(self):
        found = dict(jobs())
        for key, job in found.items():
            for step in job.get("steps") or ():
                if not isinstance(step, dict) or not str(step.get("uses", "")).startswith("useblacksmith/"):
                    continue
                with self.subTest(job=key, step=step.get("name") or step["uses"]):
                    self.assertTrue(skipped_when_off(job.get("if")) or skipped_when_off(step.get("if")))
        self.assertTrue(skipped_when_off(found["ci-cloud-overflow-probe.yml#probe"].get("if")))
        self.assertTrue(skipped_when_off(found["ci-cloud-overflow-probe.yml#watch"].get("if")))


class Wrap(unittest.TestCase):
    def test_wrap_keeps_the_original_and_unwrap_returns_it(self):
        for value in ("${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}", "${{ matrix.runner }}",
                      "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}"):
            with self.subTest(value=value):
                wrapped = blacksmith_off.wrap(value)
                self.assertTrue(wrapped.startswith("${{ vars.CI_BLACKSMITH_OFF == '1' && "))
                self.assertTrue(wrapped.endswith(" || (" + value[4:-3] + ") }}"))
                self.assertEqual(blacksmith_off.unwrap(wrapped), value)
                self.assertFalse(blacksmith_off.needs_wrap(wrapped))

    def test_routes_by_family(self):
        self.assertIn("'cmux-fleet-linux-x64'", blacksmith_off.wrap("${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        mac = blacksmith_off.wrap("${{ needs.pick.outputs.label || 'blacksmith-6vcpu-macos-15' }}")
        self.assertIn(f"{blacksmith_off.FORK} && 'macos-15' || 'glaeda-std-xcode-26.6'", mac)
        signing = blacksmith_off.wrap("${{ 'blacksmith-6vcpu-macos-26' }}", "apple-signing-release")
        self.assertIn("'glaeda-trusted-next-signing'", signing)
        named = blacksmith_off.wrap("${{ vars.X == '1' && 'glaeda-side-std-xcode-26.6' || 'blacksmith-6vcpu-macos-26' }}")
        self.assertIn("|| 'glaeda-side-std-xcode-26.6')", named)
        self.assertIn("'windows-2025'", blacksmith_off.wrap("${{ 'blacksmith-4vcpu-windows-2025' }}"))
        self.assertIn("'ubuntu-24.04-arm'", blacksmith_off.wrap("${{ 'blacksmith-4vcpu-ubuntu-2404-arm' }}"))


if __name__ == "__main__":
    sys.exit(unittest.main())
