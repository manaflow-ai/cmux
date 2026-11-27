import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "sidebar-perf-validate.py"
SPEC = importlib.util.spec_from_file_location("sidebar_perf_validate", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write(root: Path, name: str, value: dict) -> None:
    (root / name).write_text(json.dumps(value), encoding="utf-8")


class SidebarPerfValidateTests(unittest.TestCase):
    def test_passes_live_and_mirror_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "summary-pass.json", {
                "has_counters": True,
                "failures": [],
                "ticks": {"counters": {"rebuilds": 0, "list_reloads": 0, "row_patches": 20, "row_configures": 20}},
                "scroll_ticking": {"frames": {"p99_ms": 12.0, "max_ms": 16.0}},
            })
            write(root, "mirror-rebuild-pass.json", {
                "view_calls": 40, "rebuilds": 20, "mirror_ms_total": 8.0, "main_ms_total": 12.0,
            })
            self.assertEqual(MODULE.main([str(root), "--require-counters", "--max-frame-p99-ms", "16.7"]), 0)

    def test_rejects_structural_and_frame_regressions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "summary-fail.json", {
                "has_counters": True,
                "ticks": {"counters": {"rebuilds": 1, "list_reloads": 1, "row_patches": 2, "row_configures": 3}},
                "scroll": {"frames": {"p99_ms": 20.0}},
            })
            self.assertEqual(MODULE.main([str(root), "--require-counters", "--max-frame-p99-ms", "16.7"]), 1)

    def test_rejects_missing_metrics_and_harness_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "summary-missing.json", {"has_counters": True, "failures": ["no view"]})
            write(root, "mirror-missing.json", {"view_calls": 0, "rebuilds": 0})
            self.assertEqual(MODULE.main([str(root), "--require-counters"]), 1)

    def test_discovery_ignores_unrelated_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, "other.json", {})
            self.assertEqual(MODULE.main([str(root)]), 2)


if __name__ == "__main__":
    unittest.main()
