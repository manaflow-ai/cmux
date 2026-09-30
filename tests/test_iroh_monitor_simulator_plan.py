import subprocess
import unittest
from pathlib import Path

DRIVER = Path(__file__).resolve().parents[1] / "scripts/run-iroh-release-gate.sh"


class MonitorSimulatorPlanTests(unittest.TestCase):
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
