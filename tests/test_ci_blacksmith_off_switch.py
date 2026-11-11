#!/usr/bin/env python3
"""feat-cmux-next's half of CI_BLACKSMITH_OFF: what main's writers put in the runner variables is accepted here.

Leo, 2026-11-10: "just stop using blacksmith temporarily". main's scheduled watch (ci-cloud-overflow-probe.yml) writes
the variables; while CI_BLACKSMITH_OFF is '1' it points LINUX_RUNNER at cmux-fleet-linux-x64 and every RUNNER_POOLS
pool at its declared `off` label. This checks that feat-cmux-next's routing takes those values:

- the pools copy declares the same non-Blacksmith `off` label for every Blacksmith pool;
- each runs-on that reads a pool, with the pools at their off labels, resolves off Blacksmith (unless a literal
  Blacksmith label in the same expression can still win, which the PR lists as not covered);
- the live signing-runner-variables guard and scripts/ci/signing_runner_variables.py accept cmux-fleet-linux-x64, so
  LINUX_RUNNER on the GCP fleet does not turn every pull request red.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import signing_runner_variables  # noqa: E402
from runs_on_labels import resolve_labels  # noqa: E402

GCP_FLEET_LINUX = "cmux-fleet-linux-x64"
POOL_READ = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.([a-z0-9_]+)")


def pools() -> dict:
    return {name: spec for name, spec in json.loads((ROOT / ".github/runners.json").read_text())["pools"].items()
            if not name.startswith("$")}


class OffLabels(unittest.TestCase):
    def test_every_blacksmith_pool_declares_a_non_blacksmith_off_label(self):
        for name, spec in pools().items():
            if spec.get("hosted"):
                continue
            with self.subTest(pool=name):
                off = spec.get("off")
                self.assertTrue(off)
                self.assertFalse(off.startswith("blacksmith-"), off)
                self.assertTrue(off == GCP_FLEET_LINUX or off.startswith("glaeda-") or spec.get("off_why"), off)

    def test_pool_reads_resolve_off_blacksmith_with_the_pools_off(self):
        declared = pools()
        off = {name: spec.get("off") or spec["members"][0] for name, spec in declared.items()}
        checked = 0
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
            for job_name, job in (document.get("jobs") or {}).items():
                runs_on = job.get("runs-on") if isinstance(job, dict) else None
                if not isinstance(runs_on, str) or not POOL_READ.search(runs_on) or "blacksmith-" in runs_on:
                    continue  # no pool read, or a literal Blacksmith label can still win (listed in the PR)
                if re.search(r"\bvars\.(?!RUNNER_POOLS|CI_CLOUD_OVERFLOW_SAVED|CI_BLACKSMITH_OFF)[A-Z]", runs_on):
                    continue  # another variable decides first; the writers move those separately
                expression = POOL_READ.sub(lambda m: "'" + off[m.group(1)] + "'", runs_on)
                try:
                    labels = resolve_labels(expression)
                except ValueError:
                    continue
                checked += 1
                with self.subTest(job=f"{path.name}#{job_name}"):
                    self.assertEqual({label for label in labels if isinstance(label, str)
                                      and label.startswith("blacksmith-")}, set())
        self.assertGreater(checked, 50)


class SigningGuard(unittest.TestCase):
    def test_the_gcp_fleet_is_an_ephemeral_label_for_signing_variables(self):
        self.assertTrue(signing_runner_variables.allowed_value("LINUX_RUNNER", GCP_FLEET_LINUX))
        self.assertFalse(signing_runner_variables.allowed_value("LINUX_RUNNER", "glaeda-std-xcode-26.6"))
        self.assertFalse(signing_runner_variables.allowed_value("LINUX_RUNNER", "cmux-fleet-linux-x64-evil"))

    def test_the_live_guard_accepts_the_gcp_fleet(self):
        document = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text(encoding="utf-8"))
        run = document["jobs"]["signing-runner-variables"]["steps"][0]["run"]
        self.assertIn('""|blacksmith-*|ubuntu-*|cmux-fleet-linux-x64)', run)


if __name__ == "__main__":
    sys.exit(unittest.main())
