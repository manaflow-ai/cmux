import subprocess
import unittest
from pathlib import Path
import yaml

DRIVER = Path(__file__).resolve().parents[1] / "scripts/run-iroh-release-gate.sh"
WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/iroh-release-gate.yml"


class MonitorSimulatorPlanTests(unittest.TestCase):
    def test_workflow_bounds_the_gate_step(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        step = next(
            step for step in workflow["jobs"]["simulator-e2e"]["steps"]
            if step.get("name") == "Run Iroh gate"
        )
        self.assertIn("timeout-minutes", step)
        self.assertIn("75", step["timeout-minutes"])
        self.assertIn("25", step["timeout-minutes"])

    def test_gate_script_has_phase_timeout_and_reason(self):
        script = DRIVER.read_text(encoding="utf-8")
        self.assertIn("PHASE_TIMEOUT_SECONDS", script)
        self.assertIn("run_phase_with_timeout prewarm", script)
        self.assertIn("phase '{label}' timed out", script)
        self.assertIn("build phase timed out", script)
        self.assertIn("phase 'report' timed out", script)
        self.assertIn("phase 'launch' timed out", script)

    def test_prebuilt_soak_accepts_a_dedicated_simulator(self):
        result = subprocess.run(
            [str(DRIVER), "--mode", "relay-only", "--tag", "soki", "--skip-build",
             "--soak-profile", "basic", "--simulator-id", "123e4567-e89b-42d3-a456-426614174000",
             "--print-plan"], text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "app-rpc")

    def test_persistent_device_requires_a_soak_and_prebuilt_app(self):
        for extra in ([], ["--skip-build"], ["--soak-profile", "basic"]):
            result = subprocess.run(
                [str(DRIVER), "--mode", "relay-only", "--tag", "soki", *extra,
                 "--simulator-id", "123e4567-e89b-42d3-a456-426614174000", "--print-plan"],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("requires a prebuilt staging soak", result.stderr)


if __name__ == "__main__":
    unittest.main()
