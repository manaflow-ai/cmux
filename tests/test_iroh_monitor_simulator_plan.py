import subprocess
import unittest
from pathlib import Path

DRIVER = Path(__file__).resolve().parents[1] / "scripts/run-iroh-release-gate.sh"
NO_LISTENER = "no longer runs the iroh phone listener"


def run_driver(*args):
    return subprocess.run([str(DRIVER), *args], text=True, capture_output=True)


class IrohReleaseGatePlanTests(unittest.TestCase):
    """The app-rpc modes paired the iOS app with the tagged Mac app's iroh phone
    listener, which the cmux-next Mac app removed. They are refused before any
    build, simulator or credential work; the transport-only modes still plan."""

    def test_app_rpc_modes_are_refused_with_one_message(self):
        for mode in ("automatic", "relay-only", "relay-expiry"):
            for extra in ([], ["--print-plan"], ["--skip-build", "--soak-profile", "basic"]):
                result = run_driver("--mode", mode, "--tag", "soki", *extra)
                self.assertEqual(result.returncode, 2, (mode, extra, result.stderr))
                self.assertIn(f"--mode {mode} has no target", result.stderr)
                self.assertIn(NO_LISTENER, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_transport_modes_still_plan(self):
        for mode, plan in (("direct-only", "simulator-direct-transport"),
                           ("private-path", "host-private-path-transport")):
            result = run_driver("--mode", mode, "--tag", "soki", "--print-plan")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), plan)

    def test_app_rpc_flags_are_refused_on_transport_modes(self):
        for extra in (["--production"], ["--soak-profile", "basic"],
                      ["--simulator-id", "123e4567-e89b-42d3-a456-426614174000"],
                      ["--staging-base-url", "https://example.com"]):
            result = run_driver("--mode", "direct-only", "--tag", "soki", *extra, "--print-plan")
            self.assertEqual(result.returncode, 2, (extra, result.stderr))
            self.assertIn(f"{extra[0]} belonged to the removed app-rpc modes", result.stderr)


if __name__ == "__main__":
    unittest.main()
