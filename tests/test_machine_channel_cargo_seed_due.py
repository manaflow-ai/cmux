#!/usr/bin/env python3
"""scripts/ci/machine_channel_cargo_seed_due.py and the seed workflow that runs it."""
from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("seed_due", ROOT / "scripts/ci/machine_channel_cargo_seed_due.py")
seed_due = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed_due)

NOW = datetime(2026, 11, 26, 20, 0, tzinfo=timezone.utc)
FRESH = datetime(2026, 11, 26, 19, 33, tzinfo=timezone.utc)
STALE = datetime(2026, 11, 26, 18, 30, tzinfo=timezone.utc)
X86, ARM = seed_due.LEGS


class Due(unittest.TestCase):
    def test_fresh_deltas_and_no_input_change_skip(self):
        self.assertEqual(seed_due.decide({X86: FRESH, ARM: FRESH}, [{"modified": ["cmux-tui/crates/a/src/lib.rs"]}], NOW, 60)[0], False)

    def test_a_stale_leg_is_due(self):
        self.assertEqual(seed_due.decide({X86: FRESH, ARM: STALE}, [], NOW, 60)[0], True)

    def test_a_missing_pointer_is_due(self):
        self.assertEqual(seed_due.decide({X86: FRESH, ARM: None}, [], NOW, 60)[0], True)

    def test_a_lockfile_change_is_due_however_fresh(self):
        for path in ("cmux-tui/Cargo.lock", "cmux-tui/crates/x/Cargo.lock", "cmux-tui/rust-toolchain.toml",
                     "first-party-apps/cloud/server/Cargo.lock"):
            with self.subTest(path=path):
                self.assertEqual(seed_due.decide({X86: FRESH, ARM: FRESH}, [{"modified": [path]}], NOW, 60)[0], True)

    def test_other_lockfiles_are_not_inputs(self):
        self.assertEqual(seed_due.changed_inputs([{"added": ["web/Cargo.lock", "cmux-tui/Cargo.toml"]}]), [])


class Workflow(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load((ROOT / ".github/workflows/cmux-machine-channel-cargo-seed.yml").read_text())

    def test_only_feat_cmux_next_pushes_run_it(self):
        on = self.doc.get("on", self.doc.get(True))
        self.assertEqual(list(on), ["push"])
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", self.doc["jobs"]["due"]["if"])

    def test_write_credentials_are_gated_on_the_branch(self):
        for name in ("seed-x86_64", "seed-aarch64"):
            job = self.doc["jobs"][name]
            for secret, value in job["secrets"].items():
                with self.subTest(job=name, secret=secret):
                    self.assertTrue(value.startswith("${{ github.ref == 'refs/heads/feat-cmux-next' && secrets."), value)

    def test_seeds_build_what_the_pr_head_builds(self):
        for name, target_set in (("seed-x86_64", "linux-x86_64"), ("seed-aarch64", "linux-aarch64")):
            job = self.doc["jobs"][name]
            self.assertEqual(job["uses"], "./.github/workflows/cmux-tui-build-package.yml")
            self.assertEqual(job["with"]["lto"], "thin")
            self.assertEqual(job["with"]["target_set"], target_set)
            self.assertEqual(job["with"]["linux_runner"], "cmux-linux")

    def test_a_newer_push_never_cancels_a_running_seed(self):
        self.assertIs(self.doc["concurrency"]["cancel-in-progress"], False)


if __name__ == "__main__":
    unittest.main()
