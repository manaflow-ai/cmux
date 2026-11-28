#!/usr/bin/env python3
"""The judge of transcript_fling.py (RFD 0121, app-perf.md section 6, first PR) on synthetic replies: the web arm
from debug.agent_pane perf_stats, the native arm from debug.native_transcript stats, the per-arm summary in
transcript-fling.bench.ts's shape, and that xbench's transcript_fling_rows reads it.
Run: python3 -I scripts/ci/frame-pacing/tests/test_transcript_fling.py"""
import json, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "perf-bench"))
import transcript_fling as tf  # noqa: E402

R = 1000 / 120


def perf(intervals, blank=None):
    samples = [{"interval_ms": v, "layout_ms": 1, "react_ms": 1, "other_ms": 0, "blank": False} for v in intervals]
    reply = {"frames": len(samples), "samples": samples}
    if blank is not None:
        reply["blank_frames"] = blank
    return reply


def native_stats(**extra):
    base = {"frames": 360, "late_texture_frames": 1, "late_textures": 2, "interval_p50_ms": 8.3,
            "interval_p95_ms": 8.5, "interval_max_ms": 16.7, "intervals_over_8_33": 4, "skipped_frames": 0,
            "refresh_ms": R}
    base.update(extra)
    return base


class WebArm(unittest.TestCase):
    def test_intervals_late_and_over(self):
        arm = tf.web_arm(perf([R] * 95 + [20.0] * 5, blank=3), refresh_ms=R)
        self.assertEqual(arm["frames"], 100)
        self.assertEqual(arm["frame_p50_ms"], round(R, 2))
        self.assertEqual(arm["frame_max_ms"], 20.0)
        self.assertEqual(arm["late_frames"], 5)  # exactly one 120 Hz frame is not late
        self.assertEqual(arm["over_1_5_refresh"], 5)
        self.assertEqual(arm["blank_frames"], 3)

    def test_blank_counted_from_samples_when_missing(self):
        reply = perf([R, R])
        reply["samples"][0]["blank"] = True
        self.assertEqual(tf.web_arm(reply)["blank_frames"], 1)

    def test_errors(self):
        self.assertIn("error", tf.web_arm({"error": "no pane"}))
        self.assertIn("error", tf.web_arm(perf([])))
        self.assertIn("error", tf.web_arm(None))


class NativeArm(unittest.TestCase):
    def test_prefers_presented_clock(self):
        arm = tf.native_arm(native_stats(presented_frames=300, presented_interval_p50_ms=8.33,
                                         presented_interval_p95_ms=9.1, presented_interval_max_ms=25.0,
                                         presented_intervals_over_1_5_refresh=2))
        self.assertEqual(arm["clock"], "presented")
        self.assertEqual(arm["frames"], 300)
        self.assertEqual(arm["frame_p95_ms"], 9.1)
        self.assertEqual(arm["over_1_5_refresh"], 2)
        self.assertEqual(arm["late_frames"], 4)
        self.assertEqual(arm["late_textures"], 2)

    def test_scene_clock_without_presented(self):
        arm = tf.native_arm(native_stats(presented_frames=0))
        self.assertEqual(arm["clock"], "scene")
        self.assertEqual(arm["frame_p95_ms"], 8.5)
        self.assertIsNone(arm["over_1_5_refresh"])

    def test_errors(self):
        self.assertIn("error", tf.native_arm({"error": "native transcript not in this build's app FFI"}))
        self.assertIn("error", tf.native_arm({"frames": 0}))


class Summary(unittest.TestCase):
    def test_median_over_rounds_and_shape(self):
        rounds = [tf.native_arm(native_stats(interval_p95_ms=v)) for v in (8.0, 9.0, 30.0)] + [{"error": "x"}]
        line = tf.summarize("native", rounds, "metal")
        self.assertEqual(line["schema"], tf.SCHEMA)
        self.assertEqual(line["arm"], "app-native")
        self.assertEqual(line["mode"], "fling")
        self.assertEqual(line["rows"], 3000)
        self.assertEqual(line["frame_p95_ms"], 9.0)
        self.assertEqual((line["rounds_ok"], line["rounds_run"]), (3, 4))
        self.assertEqual(line["errors"], ["x"])

    def test_unmeasured_arm_still_formats(self):
        line = tf.summarize("web", [{"error": "open chat"}], "web")
        self.assertTrue(line["not_measured"])
        self.assertEqual(line["frame_p95_ms"], 0)

    def test_percentile(self):
        self.assertIsNone(tf.percentile([], 0.5))
        self.assertEqual(tf.percentile([1, 2, 3, 4, 5], 0.5), 3)
        self.assertEqual(tf.percentile([1, 2, 3, 4, 5], 1), 5)

    def test_xbench_reads_the_lines(self):
        try:
            import xbench  # noqa: E402
        except Exception as error:  # xbench's own imports; the judge above is what this file guards
            self.skipTest(f"xbench not importable here: {error}")
        lines = [tf.summarize("web", [tf.web_arm(perf([R] * 10))], "chromium"),
                 tf.summarize("native", [tf.native_arm(native_stats())], "metal")]
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "arms.jsonl")
            with open(path, "w") as handle:
                handle.write("\n".join(json.dumps(line) for line in lines) + "\n")
            rows, md = xbench.transcript_fling_rows(path)
        self.assertIn("transcript-fling-app-native-3000-frame-p95", rows)
        self.assertIn("transcript-fling-app-web-3000-late-frames", rows)
        self.assertTrue(any("app-native" in line for line in md))


if __name__ == "__main__":
    unittest.main()
