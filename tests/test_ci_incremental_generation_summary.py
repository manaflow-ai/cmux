#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/summarize-incremental-generation.py"
spec = importlib.util.spec_from_file_location("incremental_generation_summary", SCRIPT)
assert spec and spec.loader
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class IncrementalGenerationSummaryTests(unittest.TestCase):
    def test_break_even_charges_transfer_restore_and_publication(self) -> None:
        seed = {
            "archive": {"generation_compress_seconds": 60.0},
            "worktree_upload": {"seconds": 3.0},
            "derived_data_upload": {"seconds": 12.0},
        }
        cold = {
            "arm": "cold",
            "source": {"source_transition_seconds": 50.0},
            "build": {
                "setup_seconds": 12.0,
                "package_resolve_seconds": 55.0,
                "build_wall_seconds": 1000.0,
            },
        }
        warm = {
            "arm": "warm",
            "generation_download": {"seconds": 40.0},
            "source": {"source_transition_seconds": 20.0},
            "mtime_normalization": {"normalization_seconds": 0.0},
            "derived_restore": {"derived_data_extract_seconds": 20.0},
            "build": {
                "setup_seconds": 12.0,
                "package_resolve_seconds": 55.0,
                "build_wall_seconds": 200.0,
                "swift_compile_source_file_lines": 3,
                "swift_compile_task_count": 3,
                "cas_hit_mentions": 10,
                "cas_miss_mentions": 2,
                "cas_hit_mentions_by_target": {"cmux": 1},
                "cas_miss_mentions_by_target": {"cmux": 1},
            },
        }
        result = summary.summarize(seed, cold, warm)
        self.assertEqual(result["producer_publication_proxy_seconds"], 75.0)
        self.assertEqual(result["cold_components_seconds"]["total"], 1117.0)
        self.assertEqual(result["warm_steady_state_components_seconds"]["total"], 422.0)
        self.assertEqual(result["warm_build_wall_break_even_seconds"], 895.0)
        self.assertEqual(result["steady_state_savings_seconds"], 695.0)
        self.assertTrue(result["steady_state_improves"])
        self.assertEqual(result["incremental_evidence"]["swift_compile_source_file_lines"], 3)
        self.assertEqual(result["compiler_cas_evidence"]["cmux_misses"], 1)

    def test_slow_transfer_can_kill_a_build_wall_win(self) -> None:
        seed = {
            "archive": {"generation_compress_seconds": 60.0},
            "worktree_upload": {"seconds": 3.0},
            "derived_data_upload": {"seconds": 12.0},
        }
        cold = {
            "arm": "cold",
            "source": {"source_transition_seconds": 50.0},
            "build": {
                "setup_seconds": 12.0,
                "package_resolve_seconds": 55.0,
                "build_wall_seconds": 1000.0,
            },
        }
        warm = {
            "arm": "warm",
            "generation_download": {"seconds": 900.0},
            "source": {"source_transition_seconds": 20.0},
            "derived_restore": {"derived_data_extract_seconds": 20.0},
            "build": {
                "setup_seconds": 12.0,
                "package_resolve_seconds": 55.0,
                "build_wall_seconds": 100.0,
            },
        }
        result = summary.summarize(seed, cold, warm)
        self.assertLess(100.0, 1000.0)
        self.assertFalse(result["steady_state_improves"])
        self.assertLess(result["steady_state_savings_seconds"], 0)


if __name__ == "__main__":
    unittest.main()
