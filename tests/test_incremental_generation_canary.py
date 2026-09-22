#!/usr/bin/env python3
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/incremental-generation-canary.yml"
HARNESS = ROOT / "scripts/ci/benchmark-xcode-incremental-generation.sh"


class IncrementalGenerationCanaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow_text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.workflow_text)
        cls.harness = HARNESS.read_text(encoding="utf-8")

    def test_canary_is_branch_only_and_never_runs_as_pr_authority(self) -> None:
        events = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(
            set(events),
            {"push", "workflow_dispatch"},
            "benchmark must stay isolated from pull_request, merge_group, and scheduled CI",
        )
        self.assertEqual(events["push"]["branches"], ["incgen-canary-20260921"])
        for forbidden in ("pull_request", "pull_request_target", "merge_group", "schedule"):
            self.assertNotIn(forbidden, self.workflow_text)

    def test_canary_has_no_repository_secrets_or_write_surface_beyond_locator(self) -> None:
        permissions = self.workflow["permissions"]
        self.assertEqual(permissions, {"contents": "read", "statuses": "write"})
        self.assertNotIn("secrets.", self.workflow_text)
        self.assertNotIn("actions: write", self.workflow_text)
        self.assertNotIn("contents: write", self.workflow_text)

    def test_generation_and_support_state_are_measured_separately(self) -> None:
        self.assertIn('generation_archive="$artifact_dir/generation-A.tar.zst"', self.harness)
        self.assertIn('support_archive="$artifact_dir/support-A.tar.zst"', self.harness)
        self.assertIn(
            'compress_paths "generation_A" "$generation_archive" "$worktree" "$derived"',
            self.harness,
        )
        self.assertIn(
            'compress_paths "support_A" "$support_archive" "$source_packages" "$cas"',
            self.harness,
        )
        self.assertIn('"cache_hit_diagnostic_lines"', self.harness)
        self.assertIn('"cache_miss_diagnostic_lines"', self.harness)

    def test_requested_benchmark_arms_and_path_relocation_probe_remain_present(self) -> None:
        for arm in (
            "seed_cold_A",
            "fresh_checkout_cold_dd_B",
            "fresh_checkout_restored_dd_A_to_B",
            "restored_worktree_restored_dd_A_to_B",
            "relocated_same_commit_A",
            "restored_generation_synthetic_merge",
        ):
            with self.subTest(arm=arm):
                self.assertIn(arm, self.harness)
        self.assertIn('root="/tmp/cmux-incgen-canary"', self.harness)
        self.assertIn('alt_root="/tmp/cmux-incgen-canary-relocated"', self.harness)

    def test_source_identity_probe_tracks_mtime_and_device_inode(self) -> None:
        self.assertIn('"same_mtime"', self.harness)
        self.assertIn('"same_device_inode"', self.harness)
        self.assertIn('"same_mtime_and_identity"', self.harness)
        self.assertIn("st.st_mtime_ns", self.harness)
        self.assertIn("st.st_dev", self.harness)
        self.assertIn("st.st_ino", self.harness)

    def test_transport_has_a_hard_stop_before_cross_runner_replay(self) -> None:
        self.assertIn("transport_cap_bytes=$((6 * 1024 * 1024 * 1024))", self.harness)
        consumer = self.workflow["jobs"]["consumer"]
        self.assertEqual(
            consumer["if"],
            "needs.seed.outputs.transport_viable == 'true'",
        )

    def test_benchmark_uses_disposable_runner_class_and_exact_toolchain_pin(self) -> None:
        for job_name in ("seed", "consumer"):
            job = self.workflow["jobs"][job_name]
            self.assertIn("vars.MACOS_RUNNER_15", job["runs-on"])
        self.assertEqual(self.workflow["env"]["CMUX_CI_REQUIRED_MACOS_SDK_MAJOR"], "26")
        self.assertIn("CMUX_CI_XCODE_APP_MACOS_15", self.workflow_text)

    def test_uploads_are_short_lived_measurement_artifacts(self) -> None:
        upload_blocks = re.findall(
            r"uses: actions/upload-artifact@[^\n]+\n(?P<body>(?:\s{8,}.+\n?)+)",
            self.workflow_text,
        )
        self.assertGreaterEqual(len(upload_blocks), 4)
        for block in upload_blocks:
            self.assertIn("retention-days: 1", block)
            self.assertIn("compression-level: 0", block)


if __name__ == "__main__":
    unittest.main()
