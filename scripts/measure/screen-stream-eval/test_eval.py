"""Portable report regressions; no Mac, capture grants or network needed."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("screen_eval", HERE / "eval.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def video_run(self, folder, *, requested=True):
        (folder / "repeats-requested.json").write_text('{"count":2}')
        for kind in ("key", "pointer"):
            (folder / f"latency-{kind}.json").write_text('{"g2g_ms":{"p50":10,"p95":20,"n":200}}')
        if requested:
            (folder / "video-requested.json").write_text(json.dumps({"sha256": "a" * 64, "duration_s": 20}))
        for rep, frames in enumerate((24, 30), 1):
            (folder / f"window-{rep}.json").write_text(json.dumps({"series": [
                {"unix_ms": 2000, "bytes": 1000, "frames": 60},
                {"unix_ms": 12000, "bytes": 2000, "frames": frames}]}))
            phases = [{"phase": p, "start_unix_ms": 0, "end_unix_ms": 3000}
                      for p in ("idle", "typing", "scroll")]
            phases.append({"phase": "video", "start_unix_ms": 10000, "end_unix_ms": 30000})
            (folder / f"phases-{rep}.jsonl").write_text("".join(json.dumps(p) + "\n" for p in phases))
            (folder / f"ocr-{rep}.json").write_text('{"cer":0.02}')
            (folder / f"video-media-{rep}.json").write_text(json.dumps({
                "sha256": "a" * 64, "width": 1920, "height": 1080, "nominal_fps": 30,
                "duration_s": 120, "presented_frames": 600,
                "start_unix_ms": 10000, "end_unix_ms": 30000}))

    def test_video_requires_request_and_keeps_source_frames_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            self.video_run(folder, requested=False)
            out = folder / "target.json"
            report.target("rd", folder, out)
            target = json.loads(out.read_text())
            self.assertTrue(target["ok"])
            self.assertIsNone(target["fps"]["video"])
            (folder / "video-requested.json").write_text(json.dumps({"sha256": "a" * 64, "duration_s": 20}))
            report.target("rd", folder, out)
            target = json.loads(out.read_text())
            self.assertTrue(target["ok"])
            self.assertEqual(target["fps"]["video"], 27)
            self.assertEqual(target["kbps"]["video"], 16)
            self.assertEqual(target["extra"]["repeats"][0]["video_media"]["presented_frames"], 600)

    def test_video_with_unbound_or_missing_media_cannot_report_success(self):
        for bad in (None, {"sha256": "b" * 64}, {"presented_frames": 0},
                    {"nominal_fps": None}, {"width": True}, {"duration_s": 10},
                    {"start_unix_ms": 9999}, {"end_unix_ms": 29999}):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                self.video_run(folder)
                media = folder / "video-media-1.json"
                if bad is None:
                    media.unlink()
                else:
                    media.write_text(json.dumps({**json.loads(media.read_text()), **bad}))
                out = folder / "target.json"
                report.target("rd", folder, out)
                target = json.loads(out.read_text())
                self.assertFalse(target["ok"])
                self.assertTrue(any("video" in e for e in target["errors"]))
                self.assertIsNone(target["fps"]["video"])

    def test_ocr_calibration_metadata_and_every_repeat_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            self.video_run(folder, requested=False)
            out = folder / "target.json"
            for rep in (1, 2):
                (folder / f"ocr-{rep}.json").write_text(json.dumps({
                    "cer": 0.01 * rep, "comparison_ready": True,
                    "crops": {"current_source_nonce": f"nonce-{rep}", "host_crop": [1, 2, 3, 4]}}))
            report.target("apple-high", folder, out)
            result = json.loads(out.read_text())
            self.assertIs(result["ocr"]["comparison_ready"], True)
            self.assertEqual(result["extra"]["repeats"][1]["ocr"]["crops"]["current_source_nonce"], "nonce-2")
            self.assertEqual(result["ocr"]["crops"]["current_source_nonce"], "nonce-1")
            for unready in ({"cer": None, "comparison_ready": False}, {"cer": 0.02},
                            {"cer": None, "comparison_ready": True}):
                (folder / "ocr-2.json").write_text(json.dumps(unready))
                report.target("apple-high", folder, out)
                self.assertIs(json.loads(out.read_text())["ocr"]["comparison_ready"], False)

    def test_failed_or_undeclared_repeats_cannot_be_complete(self):
        for failed_artifact in ("phases-3.jsonl", "video-media-3.json", None):
            with self.subTest(artifact=failed_artifact), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                self.video_run(folder)
                (folder / "repeats-requested.json").write_text('{"count":3}')
                for rep in (1, 2):
                    (folder / f"ocr-{rep}.json").write_text(json.dumps({
                        "cer": 0.02, "comparison_ready": True, "crops": {"nonce": str(rep)}}))
                if failed_artifact:
                    (folder / failed_artifact).write_text("")
                out = folder / "target.json"
                report.target("apple-high", folder, out)
                result = json.loads(out.read_text())
                self.assertEqual(len(result["extra"]["repeats"]), 3)
                self.assertFalse(result["ok"])
                self.assertIs(result["ocr"]["comparison_ready"], False)
                self.assertIs(result["extra"]["video_complete"], False)
                self.assertIsNone(result["fps"]["video"])
                (folder / "repeats-requested.json").unlink()
                report.target("apple-high", folder, out)
                result = json.loads(out.read_text())
                self.assertIs(result["ocr"]["comparison_ready"], False)
                self.assertIs(result["extra"]["video_complete"], False)

    def test_buckets_crossing_phase_or_guard_are_discarded(self):
        phases = {"idle": {"start_unix_ms": 2000, "end_unix_ms": 6000}}
        rows = [
            {"unix_ms": 4000, "duration_ms": 2500, "sampled_changes": 100},
            {"unix_ms": 4500, "duration_ms": 2000, "sampled_changes": 100},
            {"unix_ms": 6000, "duration_ms": 1000, "sampled_changes": 4},
            {"unix_ms": 6500, "duration_ms": 1000, "sampled_changes": 100},
        ]
        self.assertEqual(report.phase_numbers(rows, phases)[2]["idle"], 4.0)
        self.assertIsNone(report.phase_numbers(rows[:2], phases)[2]["idle"])

    def test_transport_counts_use_elapsed_time_and_accept_exact_boundary(self):
        phases = {"scroll": {"start_unix_ms": 0, "end_unix_ms": 5000}}
        rows = [
            {"unix_ms": 3000, "duration_ms": 2000, "bytes": 2000, "frames": 100},
            {"unix_ms": 4000, "bytes": 1000, "frames": 50},
        ]
        kbps, fps, _, _, _ = report.phase_numbers(rows, phases)
        self.assertEqual(kbps["scroll"], 8.0)
        self.assertEqual(fps["scroll"], 50.0)

    def test_invalid_bucket_duration_cannot_produce_a_rate(self):
        phases = {"idle": {"start_unix_ms": 0, "end_unix_ms": 6000}}
        for duration in (0, -1, None, True, "1000", float("nan"), float("inf")):
            with self.subTest(duration=duration):
                rows = [{"unix_ms": 4000, "duration_ms": duration, "sampled_changes": 6,
                         "bytes": 1000, "frames": 60}]
                kbps, fps, sampled, _, _ = report.phase_numbers(rows, phases)
                self.assertIsNone(kbps["idle"])
                self.assertIsNone(fps["idle"])
                self.assertIsNone(sampled["idle"])

    def test_sampled_changes_use_each_buckets_duration(self):
        phases = {p: {"start_unix_ms": 0, "end_unix_ms": 6000} for p in report.WINDOW_PHASES}
        rows = [
            {"unix_ms": 2000, "duration_ms": 1000, "bytes": None, "frames": None, "sampled_changes": 6},
            {"unix_ms": 4000, "duration_ms": 2000, "bytes": None, "frames": None, "sampled_changes": 9},
        ]
        kbps, fps, sampled, _, _ = report.phase_numbers(rows, phases)
        self.assertIsNone(kbps["idle"])
        self.assertIsNone(fps["idle"])
        self.assertEqual(sampled["idle"], 5.0)  # 15 changes over 3 seconds, not 2.
        self.assertEqual(report.phase_numbers(rows[:1], phases)[2]["idle"], 6.0)
        rows[0]["duration_ms"] = 0
        self.assertIsNone(report.phase_numbers(rows[:1], phases)[2]["idle"])

    def test_repeat_medians_cpu_separation_and_summary_units(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for kind in ("key", "pointer"):
                (folder / f"latency-{kind}.json").write_text(json.dumps({"g2g_ms": {"p50": 10, "p95": 20, "n": 200}}))
            for rep, cpu in enumerate((9, 2, 5), start=1):
                (folder / f"window-{rep}.json").write_text(json.dumps({
                    "series": [{"unix_ms": 2000, "frames": 60, "bytes": 1000}],
                    "extra": {"cpu_pct": cpu, "process_cpu_pct": cpu * 10, "first_frame_ms": cpu * 100}}))
                (folder / f"phases-{rep}.jsonl").write_text("".join(json.dumps({
                    "phase": p, "start_unix_ms": 0, "end_unix_ms": 3000}) + "\n" for p in report.WINDOW_PHASES))
                (folder / f"ocr-{rep}.json").write_text('{"cer": 0.027}')
            output = folder / "target.json"
            report.target("rd", folder, output)
            target = json.loads(output.read_text())
            self.assertTrue(target["ok"])
            self.assertEqual(target["extra"]["first_frame_ms"], 500)
            self.assertEqual(target["extra"]["cpu_pct"], 5)
            self.assertEqual(target["extra"]["process_cpu_pct"], 50)
            results = folder / "results.json"
            results.write_text(json.dumps({"targets": {"rd": target}}))
            summary = folder / "summary.md"
            report.summary(results, summary, None)
            self.assertIn("500.0 ms / 5.0 % / 50.0 %", summary.read_text())
            for rep in range(1, 4):
                path = folder / f"window-{rep}.json"
                window = json.loads(path.read_text())
                del window["extra"]["cpu_pct"]
                path.write_text(json.dumps(window))
            report.target("capture-only", folder, output)
            self.assertIsNone(json.loads(output.read_text())["extra"]["cpu_pct"])

    def test_apple_report_applies_peer_offset(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            raw, out = Path(directory) / "raw", Path(directory) / "out"
            raw.write_text(json.dumps({"series": [{"unix_ms": 500, "duration_ms": 1100, "frames": None}]}))
            subprocess.run(["bash", str(HERE / "targets/apple.sh"), "window-report", str(raw), str(out)],
                           env={**os.environ, "EVAL_PEER_WALL_OFFSET_MS": "10000"}, check=True)
            row = json.loads(out.read_text())["series"][0]
            self.assertEqual(row["unix_ms"], 10500)
            self.assertEqual(row["duration_ms"], 1100)


if __name__ == "__main__":
    unittest.main()
