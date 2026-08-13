import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location(
    "analyzer", ROOT / "scripts" / "analyze-ios-network-log.py"
)
analyzer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(analyzer)


class AnalyzerTests(unittest.TestCase):
    def test_correlates_latency_and_rejects_duplicate_sessions(self):
        lines = [
            "2026-08-12 10:00:00.000 UTC | App lifecycle changed (Phase: Background)",
            "2026-08-12 10:08:00.000 UTC | App lifecycle changed (Phase: Active)",
            "2026-08-12 10:08:00.100 UTC | Transport dial started (Peer: 7, Transport: Iroh, Attempt: 11)",
            "2026-08-12 10:08:00.300 UTC | Transport connected (Peer: 7, Transport: Iroh, Duration: 200 ms, Attempt: 11)",
            "2026-08-12 10:08:00.500 UTC | RPC session ready (Peer: 7, Transport: Iroh, Duration: 400 ms)",
            "2026-08-12 10:08:00.600 UTC | Transport session state changed (Peer: 7, State: Established, Session: 1)",
            "2026-08-12 10:08:00.700 UTC | Transport session state changed (Peer: 7, State: Established, Session: 2)",
        ]
        result = analyzer.analyze(lines, expected_background_seconds=480)
        self.assertEqual(result["usable_latency_ms"], [400.0])
        self.assertEqual(result["background_gaps_seconds"], [480.0])
        self.assertEqual(result["duplicate_active_session_peers"], {"7": 2})
        self.assertFalse(result["pass"])

    def test_old_export_without_peer_fields_still_checks_success(self):
        lines = [
            "+0.000 seconds | Transport dial started (Transport: Iroh, Attempt: 4)",
            "+0.250 seconds | Transport connected (Transport: Iroh, Duration: 250 ms, Attempt: 4)",
        ]
        result = analyzer.analyze(lines)
        self.assertTrue(result["pass"])
        self.assertEqual(result["connected_latency_ms"], [250.0])


if __name__ == "__main__":
    unittest.main()
