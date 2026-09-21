import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_consumer_receipt.py"
import sys
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("receipt", SCRIPT)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ConsumerReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "receipt.json"
        self.summary = Path(self.temp.name) / "summary.md"
        self.env = mock.patch.dict(os.environ, {
            "CMUX_APP_HOST_CONSUMER_RECEIPT": str(self.path),
            "CMUX_APP_HOST_RUNNER_STARTED_NS": "1000000000",
            "GITHUB_STEP_SUMMARY": str(self.summary),
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def value(self):
        return json.loads(self.path.read_text())

    def test_layer_hit_records_selected_bytes_durations_and_runner_time(self):
        with mock.patch.object(r.time, "monotonic_ns", return_value=11_000_000_000):
            r.start("app-host-unit-tests/3", layer_index_id="50")
            r.add_transfer("github-layers", 10, 10, 0.2)
            r.add_transfer("github-layers", 20, 18, 0.3)
            r.layer_hit(("app-cli", "runtime", "tests"), 0.4)
            r.restore_result(0.5, "success")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                value = r.finish()
        self.assertEqual(value["layers_requested"], ["app-cli", "runtime", "tests"])
        self.assertEqual(value["layers_restored"], ["app-cli", "runtime", "tests"])
        self.assertEqual((value["bytes_requested"], value["bytes_transferred"]), (30, 28))
        self.assertEqual(value["transfer_duration_seconds"], 0.5)
        self.assertEqual(value["restore_assembly_duration_seconds"], 0.9)
        self.assertEqual(value["overall_runner_time_seconds"], 10.0)
        self.assertEqual(value["route"], "github-layers")
        self.assertIsNone(value["fallback_reason"])
        self.assertIn("CMUX_APP_HOST_CONSUMER_RECEIPT ", output.getvalue())
        self.assertIn('"consumer": "app-host-unit-tests/3"', self.summary.read_text())

    def test_aggregate_fallback_preserves_requested_selection_and_records_reason(self):
        r.start("tests-build-and-lag", layer_index_id="")
        r.append_fallback("r2:disabled")
        r.add_transfer("github-aggregate", 100, 100, 1.25)
        r.aggregate_hit("github-aggregate")
        value = self.value()
        self.assertEqual(value["layers_requested"], ["app-cli", "runtime", "tests"])
        self.assertEqual(value["layers_restored"], ["app-cli", "runtime", "tests", "diagnostics"])
        self.assertEqual(value["route"], "github-aggregate")
        self.assertEqual(value["fallback_reasons"], ["layer-index-unavailable", "r2:disabled"])

    def test_layer_hit_rejects_selection_drift(self):
        r.start("tests-build-and-lag", layer_index_id="50")
        with self.assertRaisesRegex(ValueError, "authorized consumer layers"):
            r.layer_hit(("app-cli", "tests"), 0.1)


if __name__ == "__main__":
    unittest.main()
