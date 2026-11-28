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
    build, simulator or credential work; the transport-only modes are refused
    too, since the Swift package they proved was deleted."""

    def test_app_rpc_modes_are_refused_with_one_message(self):
        for mode in ("automatic", "relay-only", "relay-expiry"):
            for extra in ([], ["--print-plan"], ["--skip-build", "--soak-profile", "basic"]):
                result = run_driver("--mode", mode, "--tag", "soki", *extra)
                self.assertEqual(result.returncode, 2, (mode, extra, result.stderr))
                self.assertIn(f"--mode {mode} has no target", result.stderr)
                self.assertIn(NO_LISTENER, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_transport_modes_are_refused_now_their_package_is_gone(self):
        # CmuxIrohTransport, the Swift package direct-only and private-path proved, had no consumer and was
        # deleted with both transport gate scripts; the driver refuses those modes too, with or without app-rpc flags.
        for mode in ("direct-only", "private-path"):
            for extra in ([], ["--print-plan"], ["--production"], ["--soak-profile", "basic"],
                          ["--simulator-id", "123e4567-e89b-42d3-a456-426614174000"],
                          ["--staging-base-url", "https://example.com"]):
                result = run_driver("--mode", mode, "--tag", "soki", *extra)
                self.assertEqual(result.returncode, 2, (mode, extra, result.stderr))
                self.assertIn(f"--mode {mode} has no target", result.stderr)
                self.assertIn("CmuxIrohTransport", result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
