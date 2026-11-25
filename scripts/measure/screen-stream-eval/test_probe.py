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


if __name__ == "__main__":
    unittest.main()
