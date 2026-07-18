from pathlib import Path
import unittest


class FeatureFlagControlPlaneTests(unittest.TestCase):
    def test_control_plane_start_is_independent_of_telemetry_consent(self) -> None:
        source = Path("Sources/FeatureFlags.swift").read_text()
        start = source.index("    func start() {")
        refresh = source.index("    private func refreshRemoteFlags()", start)

        self.assertNotIn("TelemetrySettings", source[start:refresh])


if __name__ == "__main__":
    unittest.main()
