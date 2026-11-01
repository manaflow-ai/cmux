#!/usr/bin/env python3
"""git-mirror-bundle.yml publishes the bundle glaeda-git-mirror seeds a mini's full mirror from.

glaeda-git-mirror reads v1/any/latest/git-mirror-cmux- in the public NEXT bucket and the
`cmux.bundle` inside the archive it names; it accepts only keys matching
git-mirror-cmux-<10 digits>-<12 hex>. This pins that contract and the writer's trust.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import r2_cache_prune as prune  # noqa: E402

DOC = yaml.safe_load((ROOT / ".github/workflows/git-mirror-bundle.yml").read_text())
PROBE = DOC["jobs"]["probe"]
PROBE_STEPS = {step.get("name"): step for step in PROBE["steps"]}
JOB = DOC["jobs"]["bundle"]
STEPS = {step.get("name"): step for step in JOB["steps"]}
TRIGGERS = DOC.get("on", DOC.get(True))  # YAML 1.1 reads a bare `on` key as True


class Contract(unittest.TestCase):
    def test_the_reader_finds_it(self) -> None:
        env = DOC["env"]
        self.assertEqual(env["CI_CACHE_R2_PUBLIC_URL"], "https://ci-cache-next.cmux.com")
        self.assertEqual(env["CI_CACHE_R2_BUCKET"], "cmux-ci-cache-next")
        self.assertEqual(env["CI_CACHE_R2_NAMESPACE"], "any")
        fetch = STEPS["Fetch the mirrored branches"]["run"]
        self.assertIn("bundle/cmux.bundle", fetch)
        self.assertIn('echo "key=git-mirror-cmux-$(date -u +%Y%m%d%H).${head:0:12}"', fetch)
        for branch in ("main", "feat-cmux-next", "nightly-next"):
            self.assertIn(f"+refs/heads/{branch}:refs/heads/{branch}", fetch)
        # Full history: a shallow bundle could not seed a never-shallow mirror.
        self.assertNotIn("--depth", fetch)
        self.assertNotIn("--filter", fetch)
        self.assertIn("http.lowSpeedLimit=1024", fetch)
        self.assertIn("bundle verify", fetch)
        save = STEPS["Publish the bundle"]
        self.assertEqual(save["uses"], "./.github/actions/cache-save")
        self.assertEqual(save["with"]["path"], "${{ runner.temp }}/bundle")
        self.assertEqual(save["with"]["key"], "${{ steps.fetch.outputs.key }}")
        due = PROBE_STEPS["Is a bundle due"]["run"]
        self.assertIn("latest/git-mirror-cmux-", due)
        self.assertIn(r"^git-mirror-cmux-([0-9]{10})\.[0-9a-f]{12}$", due)

    def test_only_feat_cmux_next_writes_with_the_next_writer(self) -> None:
        self.assertEqual(DOC["permissions"], {})
        self.assertEqual(JOB["permissions"], {"contents": "read"})
        self.assertEqual(JOB["environment"], "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}")
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", PROBE["if"])
        self.assertIn("needs.probe.outputs.due == 'true'", JOB["if"])
        self.assertEqual(TRIGGERS["push"]["branches"], ["feat-cmux-next"])
        self.assertNotIn("pull_request", TRIGGERS)
        self.assertNotIn("pull_request_target", TRIGGERS)
        self.assertEqual(DOC["concurrency"]["group"], "git-mirror-bundle-${{ github.ref }}")
        self.assertFalse(DOC["concurrency"]["cancel-in-progress"])
        self.assertEqual(JOB["needs"], "probe")
        self.assertTrue(re.search(r"blacksmith-\d+vcpu-ubuntu", JOB["runs-on"]))

    def test_cheap_probe_is_separate_from_the_32_vcpu_bundle_writer(self) -> None:
        # Frequent pushes require only a HEAD/read; the full 2.36 GB bundle
        # remains on the larger runner and only starts when the probe says due.
        self.assertEqual(PROBE["permissions"], {})
        self.assertEqual(PROBE["outputs"]["due"], "${{ steps.due.outputs.due }}")
        self.assertIn("'blacksmith-2vcpu-ubuntu-2404'", PROBE["runs-on"])
        self.assertNotIn("vars.LINUX_RUNNER", PROBE["runs-on"])
        self.assertIn("vars.LINUX_RUNNER", JOB["runs-on"])
        self.assertNotIn("Fetch the mirrored branches", PROBE_STEPS)
        self.assertNotIn("Publish the bundle", PROBE_STEPS)
        self.assertNotIn("Is a bundle due", STEPS)
        for name in ("Fetch the mirrored branches", "Checkout the cache tooling", "Publish the bundle"):
            self.assertNotIn("if", STEPS[name])
        self.assertEqual(JOB["environment"],
                         "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}")

    def test_prune_keeps_a_day_and_the_pointed_one(self) -> None:
        key = "git-mirror-cmux-2026102709.0123456789ab"
        self.assertEqual(prune.retention_days(key), 1)
        # r2-cache.sh pins one pointer per dash-terminated prefix, and the pruner keeps every pointer's
        # target: past the stable prefix the key has no dash, so no per-hour pointer pins a bundle for good.
        self.assertNotIn("-", key.removeprefix("git-mirror-cmux-"))


if __name__ == "__main__":
    unittest.main()
