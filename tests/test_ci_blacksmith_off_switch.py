#!/usr/bin/env python3
"""CI_BLACKSMITH_OFF=1 keeps every job off Blacksmith; unset, every job routes exactly as before.

Leo, 2026-11-10: "just stop using blacksmith temporarily". scripts/ci/blacksmith_off.py wraps each runs-on that
can reach a `blacksmith-*` label; this test reads every job of every workflow and proves, with
tests/runs_on_labels.py's evaluator:

- unset, a wrapped runs-on resolves to exactly the labels of the expression it wraps (its last term);
- set, no job can resolve to a Blacksmith label, unless the job is skipped while the switch is on;
- set, a job that would have taken Blacksmith takes the GCP fleet's Linux label, an owned CI Mac, or GitHub-hosted
  arm64 Linux or Windows, and a fork's pull request event takes only a GitHub-hosted label;
- a step that uses a Blacksmith-only action (sticky disks, Testbox) is skipped while the switch is on.
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import blacksmith_off  # noqa: E402
from runs_on_labels import Unknown, resolve_labels  # noqa: E402

BLACKSMITH = re.compile(r"^blacksmith-")
HOSTED = re.compile(r"^(?:ubuntu|macos|windows)(?:-[\w.-]+)?$")
OWNED_MAC = re.compile(r"^glaeda-[a-z0-9.-]+$")
OFF_ROUTES = {blacksmith_off.GCP_FLEET_LINUX, blacksmith_off.HOSTED_LINUX_ARM, blacksmith_off.HOSTED_WINDOWS}
# GitHub refuses a workflow with an expression longer than this ("Exceeded max expression length").
MAX_EXPRESSION = 21000


def jobs():
    """(file#job, job) for every job of every workflow, as GitHub reads the scalars (all strings)."""
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


def labels(runs_on, **kwargs) -> set | None:
    try:
        return resolve_labels(runs_on, **kwargs)
    except ValueError:
        return None  # an expression the evaluator does not model (an index read); the wrapper check still applies


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

    def test_unset_routes_exactly_as_the_wrapped_expression(self):
        for key, job in jobs():
            runs_on = job.get("runs-on")
            if not isinstance(runs_on, str) or not blacksmith_off.is_wrapped(runs_on):
                continue
            with self.subTest(job=key):
                self.assertLess(len(runs_on), MAX_EXPRESSION)
                self.assertEqual(labels(runs_on), labels(blacksmith_off.unwrap(runs_on)))

    def test_set_no_job_can_take_blacksmith(self):
        for key, job in jobs():
            runs_on = job.get("runs-on")
            if runs_on is None or skipped_when_off(job.get("if")) or not_wrapped(key):
                continue
            found = labels(runs_on, blacksmith_off=True)
            if found is None:
                continue
            with self.subTest(job=key):
                self.assertEqual({label for label in found if isinstance(label, str) and BLACKSMITH.match(label)},
                                 set())

    def test_set_blacksmith_jobs_take_the_fleet_an_owned_mac_or_hosted_for_forks(self):
        fork = blacksmith_off.FORK
        for key, job in jobs():
            runs_on = job.get("runs-on")
            if not isinstance(runs_on, str) or not blacksmith_off.is_wrapped(runs_on):
                continue
            before = labels(blacksmith_off.unwrap(runs_on))
            trusted = labels(runs_on.replace(fork, "false"), blacksmith_off=True)
            forked = labels(runs_on.replace(fork, "true"), blacksmith_off=True)
            if before is None or trusted is None or forked is None:
                continue
            with self.subTest(job=key):
                new = {label for label in trusted - before if not isinstance(label, Unknown)}
                self.assertTrue(all(label in OFF_ROUTES or OWNED_MAC.match(label) for label in new), new)
                new = {label for label in forked - before if not isinstance(label, Unknown)}
                self.assertTrue(all(HOSTED.match(label) for label in new), new)

    def test_blacksmith_only_steps_and_jobs_are_skipped_when_set(self):
        for key, job in jobs():
            for step in job.get("steps") or ():
                if not isinstance(step, dict) or not str(step.get("uses", "")).startswith("useblacksmith/"):
                    continue
                with self.subTest(job=key, step=step.get("name") or step["uses"]):
                    self.assertTrue(skipped_when_off(job.get("if")) or skipped_when_off(step.get("if")))
        # The overflow probe asks Blacksmith for a runner on purpose; the switch turns it off, not around.
        probe = dict(jobs())
        self.assertTrue(skipped_when_off(probe["ci-cloud-overflow-probe.yml#probe"].get("if")))
        self.assertTrue(skipped_when_off(probe["ci-cloud-overflow-probe.yml#watch"].get("if")))


class Wrap(unittest.TestCase):
    def test_wrap_keeps_the_original_and_unwrap_returns_it(self):
        for value in ("${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}", "${{ matrix.runner }}",
                      "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}"):
            with self.subTest(value=value):
                wrapped = blacksmith_off.wrap(value)
                self.assertTrue(blacksmith_off.is_wrapped(wrapped))
                self.assertEqual(blacksmith_off.unwrap(wrapped), value)
                self.assertFalse(blacksmith_off.needs_wrap(wrapped))

    def test_routes_by_family(self):
        linux = "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        self.assertEqual(labels(blacksmith_off.wrap(linux).replace(blacksmith_off.FORK, "false"), blacksmith_off=True),
                         {"cmux-fleet-linux-x64", Unknown("vars.LINUX_RUNNER")})
        self.assertEqual(labels(blacksmith_off.wrap(linux)), labels(linux))
        mac = "${{ needs.pick.outputs.label || 'blacksmith-6vcpu-macos-15' }}"
        self.assertEqual(labels(blacksmith_off.wrap(mac, "apple-gui").replace(blacksmith_off.FORK, "true"),
                                blacksmith_off=True) - {Unknown("needs.pick.outputs.label")}, {"macos-15"})
        self.assertEqual(labels(blacksmith_off.wrap(mac, "apple-gui").replace(blacksmith_off.FORK, "false"),
                                blacksmith_off=True) - {Unknown("needs.pick.outputs.label")},
                         {"glaeda-gui-std-xcode-26.6"})
        named = "${{ vars.X == '1' && 'glaeda-side-light-xcode-26.6' || 'blacksmith-6vcpu-macos-26' }}"
        self.assertEqual(labels(blacksmith_off.wrap(named).replace(blacksmith_off.FORK, "false"), blacksmith_off=True),
                         {"glaeda-side-light-xcode-26.6"})
        for runner, want in (("blacksmith-4vcpu-windows-2025", "windows-2025"),
                             ("blacksmith-4vcpu-ubuntu-2404-arm", "ubuntu-24.04-arm"),
                             ("blacksmith-6vcpu-macos-26", "glaeda-std-xcode-26.6"),
                             ("blacksmith-16vcpu-ubuntu-2404", "cmux-fleet-linux-x64"),
                             ("glaeda-std-xcode-26.6", "glaeda-std-xcode-26.6")):
            with self.subTest(matrix_runner=runner):
                expression = blacksmith_off.wrap("${{ matrix.runner }}").replace(blacksmith_off.FORK, "false")
                self.assertEqual(labels(expression.replace("matrix.runner", f"'{runner}'"), blacksmith_off=True),
                                 {want})


if __name__ == "__main__":
    sys.exit(unittest.main())
