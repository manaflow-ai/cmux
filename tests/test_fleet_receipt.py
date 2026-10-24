import importlib.util
import json
import os
import pathlib
import tempfile
import unittest


PATH = pathlib.Path(__file__).parents[1] / ".github/actions/fleet-receipt/fleet_receipt.py"
spec = importlib.util.spec_from_file_location("fleet_receipt", PATH)
mod = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(mod)


class FleetReceiptTests(unittest.TestCase):
    def test_dry_run_is_default_and_does_not_execute(self):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "receipt.json"
            code = mod.main(["--command", "touch SHOULD_NOT_EXIST", "--output", str(out)])
            self.assertEqual(code, 0)
            data = json.loads(out.read_text())
            self.assertEqual(data["status"], "planned")
            self.assertFalse((pathlib.Path.cwd() / "SHOULD_NOT_EXIST").exists())
            self.assertEqual(len(data["command_sha256"]), 64)

    def test_execute_records_pass_and_runner_fields(self):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "nested/receipt.json"
            old_provider = os.environ.get("FLEET_PROVIDER")
            os.environ["FLEET_PROVIDER"] = "test"
            try:
                code = mod.main(["--execute", "--command", "exit 0", "--output", str(out)])
            finally:
                if old_provider is None:
                    os.environ.pop("FLEET_PROVIDER", None)
                else:
                    os.environ["FLEET_PROVIDER"] = old_provider
            self.assertEqual(code, 0)
            data = json.loads(out.read_text())
            self.assertEqual(data["status"], "passed")
            self.assertEqual(data["exit_code"], 0)
            self.assertEqual(data["runner"]["provider"], "test")
            self.assertGreaterEqual(data["duration_ms"], 0)

    def test_failed_command_propagates_exit_code_and_no_command_text(self):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "receipt.json"
            code = mod.main(["--execute", "--command", "exit 7", "--output", str(out)])
            self.assertEqual(code, 7)
            data = json.loads(out.read_text())
            self.assertEqual(data["status"], "failed")
            self.assertNotIn("command", data)

    def test_timeout_terminates_command_group(self):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "receipt.json"
            code = mod.main(["--execute", "--timeout-seconds", "0.05", "--command", "sleep 2", "--output", str(out)])
            self.assertEqual(code, 124)
            self.assertEqual(json.loads(out.read_text())["status"], "timed_out")


if __name__ == "__main__":
    unittest.main()
