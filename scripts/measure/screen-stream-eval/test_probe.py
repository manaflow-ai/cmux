import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("screen_eval_probe", HERE / "probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def results(*, link="lan via tailnet: host at 100.64.0.17", apple=True, cmux_p50=142.0):
    targets = {
        "rd": {"latency": {"key": {"p50_ms": cmux_p50}}, "fps": {"scroll": 60.0}},
    }
    if apple:
        targets["apple-rfb"] = {"latency": {"key": {"p50_ms": 157.0}}}
    return {"schema": probe.SOURCE_SCHEMA, "run": {"at": "2026-11-16T08:00:00Z", "host": "cmux17",
            "viewer": "cmux20", "link": link, "rev": "abc"}, "targets": targets}


class ProbeTests(unittest.TestCase):
    def write(self, value):
        folder = tempfile.TemporaryDirectory()
        source = Path(folder.name) / "results.json"
        destination = Path(folder.name) / "probe.json"
        source.write_text(json.dumps(value))
        return folder, source, destination

    def test_two_mac_with_apple_comparison_passes_under_target(self):
        folder, source, destination = self.write(results())
        try:
            row = probe.publish(source, destination)
            self.assertEqual(row["outcome"], "pass")
            self.assertTrue(row["complete"])
            self.assertEqual(row["metrics"]["apple_key_p50_ms"], 157.0)
            self.assertEqual(row["run"]["viewer"], "cmux20")
            self.assertEqual(json.loads(destination.read_text()), row)
        finally:
            folder.cleanup()

    def test_one_mac_is_unknown_even_with_fast_rd(self):
        folder, source, destination = self.write(results(link="loopback: host and viewer on one Mac"))
        try:
            row = probe.publish(source, destination)
            self.assertEqual(row["outcome"], "unknown")
            self.assertFalse(row["complete"])
            self.assertIn("two-Mac link evidence is missing", row["errors"])
        finally:
            folder.cleanup()

    def test_missing_apple_is_unknown_not_a_green_comparison(self):
        folder, source, destination = self.write(results(apple=False))
        try:
            row = probe.publish(source, destination)
            self.assertEqual(row["outcome"], "unknown")
            self.assertIsNone(row["metrics"]["apple_key_p50_ms"])
            self.assertIn("Apple comparison key latency p50 is missing", row["errors"])
        finally:
            folder.cleanup()

    def test_complete_but_over_target_fails(self):
        folder, source, destination = self.write(results(cmux_p50=161.0))
        try:
            row = probe.publish(source, destination)
            self.assertEqual(row["outcome"], "fail")
            self.assertFalse(row["metrics"]["under_target"])
        finally:
            folder.cleanup()

    def test_unrelated_target_errors_do_not_hide_required_comparison(self):
        value = results()
        value["targets"]["webrtc"] = {"errors": ["unrelated target failed"]}
        folder, source, destination = self.write(value)
        try:
            row = probe.publish(source, destination)
            self.assertEqual(row["outcome"], "pass")
            self.assertNotIn("webrtc: unrelated target failed", row["errors"])
        finally:
            folder.cleanup()

    def presented(self, cmux_p95, apple_p95, apple_name="apple-high", link="lan: host at 172.20.21.249"):
        value = results(link=link)
        value["targets"]["rd-present"] = {"latency": {"key": {"p50_ms": 40.0, "p95_ms": cmux_p95}}}
        value["targets"][apple_name] = {"latency": {"key": {"p50_ms": 60.0, "p95_ms": apple_p95}}}
        folder, source, destination = self.write(value)
        try:
            return probe.publish(source, destination)["metrics"]["presented"]
        finally:
            folder.cleanup()

    def test_presented_passes_under_100_ms_and_below_apple(self):
        row = self.presented(80.0, 95.0)
        self.assertEqual(row["outcome"], "pass")
        self.assertEqual(row["apple_target"], "apple-high")
        self.assertTrue(row["cmux_beats_apple_p95"])

    def test_presented_fails_when_apple_is_faster_or_over_target(self):
        self.assertEqual(self.presented(80.0, 70.0)["outcome"], "fail")
        self.assertEqual(self.presented(120.0, 200.0)["outcome"], "fail")

    def test_presented_never_compares_against_apple_rfb_decode(self):
        row = self.presented(80.0, 95.0, apple_name="apple-rfb")
        self.assertEqual(row["outcome"], "unknown")
        self.assertIsNone(row["apple_target"])
        self.assertIn("Apple presented key p95 is missing", row["errors"])

    def test_presented_one_mac_is_unknown(self):
        row = self.presented(10.0, 95.0, link="loopback: host and viewer on one Mac")
        self.assertEqual(row["outcome"], "unknown")


if __name__ == "__main__":
    unittest.main()
