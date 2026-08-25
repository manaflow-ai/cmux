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

    def test_parses_app_log_timestamp_format_and_exposes_route_diagnosis(self):
        lines = [
            "cmux network diagnostics log · cmux · built 2026-08-12",
            "2026-08-12T10:00:00.000Z Direct dial plan assembled (Peer: 9, Public paths: 1, Private fallback paths: 0, Public relay URLs: 1)",
            "2026-08-12T10:00:00.100Z Iroh route discovery succeeded (Peer: 9, Duration: 340 ms)",
            "2026-08-12T10:00:00.200Z Direct dial leg failed (Peer: 9, Leg: Public paths, Failure: No route available, Duration: 5.000 seconds)",
            "2026-08-12T10:00:00.300Z Transport dial failed (Peer: 9, Transport: Iroh, Failure: No route available, Duration: 5.000 seconds, Attempt: 4)",
        ]
        result = analyzer.analyze(lines)
        self.assertEqual(result["event_count"], 4)
        self.assertEqual(result["dial_failures"], {"no_route": 1})
        self.assertEqual(result["phase_failures"], {"Public paths/no_route": 1})
        self.assertEqual(result["discovery_durations_ms"], [340.0])
        self.assertEqual(
            result["dial_plans"],
            [{"public_paths": 1, "private_fallback_paths": 0, "public_relay_urls": 1}],
        )
        self.assertEqual(
            result["route_policy"],
            {
                "assessment": "public_relay_present",
                "empty_plans": 0,
                "plans_observed": 1,
                "plans_with_public_relay": 1,
                "plans_without_public_relay": 0,
                "public_direct_paths_observed": 0,
                "public_relay_urls_observed": 1,
                "private_fallback_paths_observed": 0,
            },
        )

    def test_distinguishes_missing_relay_policy_from_old_log_without_plan_events(self):
        missing_relay = analyzer.analyze(
            [
                "2026-08-12T10:00:00.000Z Direct dial plan assembled (Peer: 9, Public paths: 1, Private fallback paths: 0, Public relay URLs: 0)",
                "2026-08-12T10:00:00.100Z Transport dial failed (Peer: 9, Transport: Iroh, Failure: No route available, Attempt: 4)",
            ]
        )
        self.assertEqual(missing_relay["route_policy"]["assessment"], "no_public_relay")
        self.assertIn(
            "no public relay URL was present in recorded dial plans",
            missing_relay["failures"],
        )

        legacy = analyzer.analyze(
            [
                "2026-08-12T10:00:00.100Z Transport dial failed (Transport: Iroh, Failure: No route available, Attempt: 4)",
            ]
        )
        self.assertEqual(
            legacy["route_policy"]["assessment"],
            "plan_diagnostics_unavailable",
        )

    def test_reports_discovery_and_relay_policy_shape_without_secrets(self):
        result = analyzer.analyze(
            [
                "2026-08-12T10:00:00.000Z Relay policy refresh started",
                "2026-08-12T10:00:00.050Z Relay policy refreshed",
                "2026-08-12T10:00:00.100Z Iroh route discovery succeeded (Transport: Iroh, Bindings: 2, Duration: 340 ms, Relay fleet: 3)",
                "2026-08-12T10:00:00.200Z Network reachability changed (Network: Online)",
            ]
        )
        self.assertEqual(result["relay_policy_outcomes"], {"started": 1, "succeeded": 1})
        self.assertEqual(
            result["discovery_shapes"],
            [{"bindings": 2, "relay_fleet": 3}],
        )
        self.assertEqual(result["network_reachability"], {"Online": 1})

    def test_normalizes_no_route_found_from_a_leg_only_failure(self):
        result = analyzer.analyze(
            [
                "2026-08-12T10:00:00.000Z Direct dial plan assembled (Peer: 9, Public paths: 1, Private fallback paths: 0, Public relay URLs: 0)",
                "2026-08-12T10:00:05.000Z Direct dial leg failed (Peer: 9, Leg: Public paths, Failure: No route found)",
            ]
        )
        self.assertEqual(result["phase_failures"], {"Public paths/no_route": 1})
        self.assertEqual(result["route_policy"]["assessment"], "no_public_relay")

    def test_handles_iso_offsets_and_explicit_duration_units(self):
        result = analyzer.analyze(
            [
                "2026-08-12T10:00:00.000+02:00 Transport dial started (Transport: Iroh, Attempt: 4)",
                "2026-08-12T08:00:00.250Z Transport connected (Transport: Iroh, Duration: 250 milliseconds, Attempt: 4)",
                "2026-08-12T08:00:00.300Z Iroh route discovery succeeded (Duration: 1.5 seconds)",
            ]
        )
        self.assertEqual(result["connected_latency_ms"], [250.0])
        self.assertEqual(result["discovery_durations_ms"], [1500.0])


if __name__ == "__main__":
    unittest.main()
