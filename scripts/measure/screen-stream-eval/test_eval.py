"""Report contract: complete buckets, required bytes, honest repeats; no Mac, grants or network."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("screen_eval", HERE / "eval.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
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
        with tempfile.TemporaryDirectory() as directory:
            raw, out = Path(directory) / "raw", Path(directory) / "out"
            raw.write_text(json.dumps({"series": [{"unix_ms": 500, "duration_ms": 1100, "frames": None}]}))
            subprocess.run(["bash", str(HERE / "targets/apple.sh"), "window-report", str(raw), str(out)],
                           env={**os.environ, "EVAL_PEER_WALL_OFFSET_MS": "10000"}, check=True)
            row = json.loads(out.read_text())["series"][0]
            self.assertEqual(row["unix_ms"], 10500)
            self.assertEqual(row["duration_ms"], 1100)

    def test_buckets_crossing_phase_or_guard_are_discarded(self):
        phases = {'idle': {'start_unix_ms':2000, 'end_unix_ms':6000}}
        rows = [{'unix_ms':4000,'duration_ms':2500,'bytes':1000,'frames':100},
                {'unix_ms':4500,'duration_ms':2000,'bytes':1000,'frames':100},
                {'unix_ms':6000,'duration_ms':1000,'bytes':1000,'frames':4},
                {'unix_ms':6500,'duration_ms':1000,'bytes':1000,'frames':100}]
        self.assertEqual(report.phase_numbers(rows, phases)[1]['idle'], 4)
        self.assertIsNone(report.phase_numbers(rows[:2], phases)[1]['idle'])

    def test_transport_counts_use_elapsed_time_and_exact_boundary(self):
        phases = {'scroll':{'start_unix_ms':0,'end_unix_ms':5000}}
        rows = [{'unix_ms':3000,'duration_ms':2000,'bytes':2000,'frames':100},
                {'unix_ms':4000,'bytes':1000,'frames':50}]
        kbps, fps, _, _, _ = report.phase_numbers(rows, phases)
        self.assertEqual(kbps['scroll'], 8)
        self.assertEqual(fps['scroll'], 50)

    def test_invalid_duration_is_not_a_rate(self):
        phases = {'idle':{'start_unix_ms':0,'end_unix_ms':6000}}
        for duration in (0, -1, None, True, '1000', float('nan'), float('inf')):
            with self.subTest(duration=duration):
                rows = [{'unix_ms':4000,'duration_ms':duration,'bytes':1000,'frames':60}]
                self.assertIsNone(report.phase_numbers(rows, phases)[0]['idle'])

    def fixture(self, folder, missing_bytes=False):
        for kind in ('key','pointer'):
            (folder/f'latency-{kind}.json').write_text(json.dumps({'g2g_ms':{'p50':10}}))
        for repeat, metrics in enumerate(({'on_time_fps':24,'psnr_db':42},
                                         {'on_time_fps':None,'psnr_db':None}, {}), 1):
            row = {'unix_ms':2000,'frames':60}
            if not missing_bytes:
                row['bytes'] = 1000
            (folder/f'window-{repeat}.json').write_text(json.dumps({'series':[row],
                'extra':{'netem_metrics':metrics}}))
            (folder/f'phases-{repeat}.jsonl').write_text(''.join(json.dumps({'phase':phase,
                'start_unix_ms':0,'end_unix_ms':3000})+'\n' for phase in report.WINDOW_PHASES))
            (folder/f'ocr-{repeat}.json').write_text('{"cer":0.01}')

    def test_rd_requires_bytes_even_when_frames_are_present(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            self.fixture(folder, missing_bytes=True)
            report.target('rd', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertFalse(result['ok'])
            self.assertTrue(any('no numbers' in e for e in result['errors']))

    def test_mixed_repeats_keep_missing_evidence_without_first_repeat_aggregate(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            self.fixture(folder)
            report.target('rd', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertTrue(result['ok'])
            self.assertNotIn('netem_metrics', result['extra'])
            repeats = result['extra']['repeats']
            self.assertEqual(repeats[0]['window_netem_metrics']['on_time_fps'], 24)
            self.assertIsNone(repeats[1]['window_netem_metrics']['on_time_fps'])
            self.assertEqual(repeats[2]['window_netem_metrics'], {})

    def test_only_a_viewer_without_byte_access_may_report_sampled_changes(self):
        row = {'unix_ms':2000,'duration_ms':1000,'bytes':None,'frames':None,'sampled_changes':30}
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            self.fixture(folder, missing_bytes=True)
            # Screen Sharing.app: the real window-report output, as eval.py reads it.
            raw = folder/'apple.raw'
            raw.write_text(json.dumps({'series':[row], 'extra':{'first_frame_ms':300, 'cpu_pct':4,
                'mode':'high', 'viewer':'Screen Sharing.app', 'readiness':{},
                'bytes_method':'Screen Sharing.app transport bytes are not exposed', 'bytes_unavailable':True}}))
            for repeat in range(1, 4):
                subprocess.run(['bash', str(HERE/'targets/apple.sh'), 'window-report', str(raw),
                                str(folder/f'window-{repeat}.json')], check=True)
            report.target('apple', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertTrue(result['ok'], result['errors'])
            self.assertIsNone(result['kbps']['idle'])
            self.assertEqual(result['sampled_fps']['idle'], 30)
            # gui-viewer.sh measures bytes with nettop (its own `bytes_method`): null bytes stay a failure.
            for repeat in range(1, 4):
                (folder/f'window-{repeat}.json').write_text(json.dumps({'series':[row], 'extra':{
                    'bytes_method':'nettop bytes_in of the viewer process, all sockets'}}))
            report.target('moonlight', folder, folder/'out.json')
            result = json.loads((folder/'out.json').read_text())
            self.assertFalse(result['ok'])
            self.assertTrue(any('no numbers' in e for e in result['errors']))

    def test_window_only_exemption_does_not_invent_window_data(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            (folder/'window-only').touch()
            report.target('window-only', folder, folder/'out.json')
            errors = json.loads((folder/'out.json').read_text())['errors']
            self.assertFalse(any(e.startswith('latency') for e in errors))
            self.assertIn('window: no repeat ran', errors)

    def test_iphone_sim_host_stop_removes_its_set_and_two_macs_are_refused(self):
        with tempfile.TemporaryDirectory() as name:
            state = Path(name)
            env = {**os.environ, "EVAL_STATE": str(state), "EVAL_ROOT": str(HERE.parents[2]), "EVAL_BIN": str(state)}
            script = str(HERE / "targets/iphone-sim.sh")
            # Nothing made yet (the harness's exit trap before any view): a no-op that succeeds.
            subprocess.run(["bash", script, "host-stop"], env=env, check=True, capture_output=True)
            sims = Path(tempfile.mkdtemp(prefix="iphsim.", dir="/tmp"))
            (state / "sims").write_text(f"{sims}\n")
            (state / "udid").write_text("UDID\n")
            subprocess.run(["bash", script, "host-stop"], env=env, check=True, capture_output=True)
            self.assertFalse(sims.exists())
            self.assertFalse((state / "sims").exists() or (state / "udid").exists())
            for var in ("EVAL_BIND", "EVAL_PEER"):
                for verb in ("build", "host-start", "latency-view"):
                    done = subprocess.run(["bash", script, verb, "key", "1", str(state / "raw")],
                                          env={**env, var: "100.64.0.1"}, capture_output=True, text=True)
                    self.assertEqual(done.returncode, 1)
                    self.assertIn("one Mac only", done.stderr)

    def test_iphone_sim_report_keeps_presented_and_decoded_and_needs_no_window(self):
        app = {"g2g_ms": {"n": 190, "p50": 61.5, "p95": 80.0},
               "decoded_g2g_ms": {"n": 190, "p50": 48.0, "p95": 66.0},
               "decode_to_present_ms": {"n": 190, "p50": 13.5, "p95": 17.0},
               "lost": 10, "decoded_not_presented": 2, "rtt_ms": 2, "jitter_buffer_ms": 5, "decode_ms_mean": 1.5,
               "present_clock": None}
        # Both renderers' clocks reach results.json, so one harness compares them.
        clocks = {"key": {"renderer": "RTCMTLVideoView", "presented": "Metal presentedTime ...", "hook_problem": None,
                          "presents": 900, "presented_time": 900, "handler_time": 0},
                  "pointer": {"renderer": "AVSampleBufferDisplayLayer", "presented": "targetTimestamp ...",
                              "hook_problem": None, "display_link_ticks": 1800, "tick_ms_min": 16.6, "tick_ms_max": 16.8}}
        with tempfile.TemporaryDirectory() as name:
            folder, state = Path(name), Path(name) / "state"
            state.mkdir()
            (folder / "latency-only").touch()
            env = {**os.environ, "EVAL_STATE": str(state), "EVAL_ROOT": str(HERE.parents[2]), "EVAL_BIN": str(state)}
            caps = subprocess.run(["bash", str(HERE / "targets/iphone-sim.sh"), "caps"], env=env, check=True,
                                  capture_output=True, text=True).stdout.strip()
            self.assertEqual(caps, "latency-only")
            for kind in ("key", "pointer"):
                raw = state / f"latency-{kind}.raw"
                raw.write_text("app noise\niphonesim: " + json.dumps({**app, "present_clock": clocks[kind]}) + "\n")
                subprocess.run(["bash", str(HERE / "targets/iphone-sim.sh"), "latency-report", kind, str(raw),
                                str(folder / f"latency-{kind}.json")], env=env, check=True)
            report.target("iphone-sim", folder, folder / "target.json")
            target = json.loads((folder / "target.json").read_text())
            self.assertTrue(target["ok"], target["errors"])
            self.assertEqual(target["latency"]["key"], {"p50_ms": 61.5, "p95_ms": 80.0, "n": 190, "lost": 10})
            present = target["split"]["key"]["present"]
            self.assertEqual(present["decoded_ms"], {"n": 190, "p50": 48.0, "p95": 66.0})
            self.assertEqual(present["decode_to_present_ms"]["p50"], 13.5)
            self.assertEqual(present["decoded_not_presented"], 2)
            for kind in ("key", "pointer"):
                self.assertEqual(target["split"][kind]["present"]["clock"], clocks[kind])
            self.assertEqual(target["split"]["key"]["transport_ms"], 6.0)
            results = folder / "results.json"
            results.write_text(json.dumps({"targets": {"iphone-sim": target}}))
            report.summary(results, folder / "summary.md", None)
            self.assertIn("48.0 ms (66.0 ms) / 61.5 ms (80.0 ms) / 13.5 ms (17.0 ms)", (folder / "summary.md").read_text())




if __name__ == "__main__":
    unittest.main()
