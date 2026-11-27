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


class ExternalContenderTests(unittest.TestCase):
    def test_no_host_grants_targets_skip_the_tcc_preflight_and_the_local_marker(self):
        # A target whose host runs elsewhere (iphone-sim-linux) needs no grant on this Mac: a run of
        # only such targets neither runs the preflight nor starts the local marker; any other keeps both.
        import shutil
        target = """case "$1" in
  caps) echo latency-only; echo "$FAKE_CAPS" ;;
  latency-view) echo "view $2" >>"$FAKE_LOG"; echo 'iphonesim: {}' >"$4" ;;
  latency-report) echo '{}' >"$4" ;;
esac
"""
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            measure = root / "scripts/measure"
            measure.mkdir(parents=True)
            shutil.copy(HERE.parent / "screen-stream-eval.sh", measure)
            shutil.copytree(HERE, measure / "screen-stream-eval", ignore=shutil.ignore_patterns("__pycache__"))
            (measure / "screen-stream-eval/targets/remote.sh").write_text(target)
            tools = root / "tools"
            tools.mkdir()
            for tool in ("screen-eval-preflight", "screen-eval-scene", "screen-eval-ocr", "cmux-rd-marker"):
                (tools / tool).write_text(f'#!/bin/sh\necho "{tool} ran" >>"$FAKE_LOG"\necho "{{}}"\n')
                (tools / tool).chmod(0o755)
            log = root / "log"
            for caps, expect_gate in (("no-host-grants", False), ("", True)):
                log.write_text("")
                done = subprocess.run(["bash", str(measure / "screen-stream-eval.sh"), f"prebuilt={tools}",
                                       "targets=remote", "samples=1"],
                                      env={**os.environ, "FAKE_CAPS": caps, "FAKE_LOG": str(log)},
                                      capture_output=True, text=True, timeout=120)
                ran = log.read_text()
                self.assertEqual("screen-eval-preflight ran" in ran, expect_gate, done.stdout[-2000:])
                if expect_gate:
                    self.assertEqual(done.returncode, 3)
                else:
                    self.assertIn('SCREEN-STREAM-EVAL-GRANTS {"skipped"', done.stdout)
                    self.assertNotIn("cmux-rd-marker ran", ran)
                    self.assertIn("view pointer", ran)
                    self.assertIn("view key", ran)

    def test_readback_numbers_and_null_for_missing(self):
        records = [{"type": "first_frame", "ms": 412.0}]
        records += [{"type": "key", "g2g_ms": float(v)} for v in range(1, 21)] + [{"type": "key", "lost": True}]
        records += [{"type": "second", "bytes": 125_000, "frames": 30, "duration_ms": 1000} for _ in range(4)]
        records += [{"type": "cpu", "side": "host", "pct": 55.5}, {"type": "meta", "codec": "h264"}]
        numbers = report.readback_numbers(records)
        self.assertEqual(numbers["key"], {"p50_ms": 10.0, "p95_ms": 19.0, "n": 20, "lost": 1})
        self.assertEqual(numbers["motion_kbps"], 1000.0)
        self.assertEqual(numbers["motion_fps"], 30.0)
        self.assertEqual(numbers["first_frame_ms"], 412.0)
        self.assertEqual(numbers["host_cpu_pct"], 55.5)
        self.assertIsNone(numbers["viewer_cpu_pct"])
        self.assertEqual(numbers["meta"], {"codec": "h264"})
        # One second without a byte count leaves kbps unmeasured instead of low.
        records.append({"type": "second", "frames": 30, "duration_ms": 1000})
        self.assertIsNone(report.readback_numbers(records)["motion_kbps"])
        self.assertEqual(report.readback_numbers([])["key"], {"p50_ms": None, "p95_ms": None, "n": None, "lost": None})

    def test_external_runs_fresh_host_per_take_and_reports_medians(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            starts = folder / "starts"
            host = f'echo started >> {starts}; touch "$EVAL_STATE/host-ready"; exec sleep 60'
            viewer = ('python3 -c \'import json,os; t=int(os.environ["EVAL_TAKE"]); '
                      'f=open(os.environ["EVAL_READBACK"],"w"); '
                      '[f.write(json.dumps({"type":"key","g2g_ms":10*t+i})+"\\n") for i in range(5)]; '
                      'f.write(json.dumps({"type":"second","bytes":1000*t,"frames":10*t})+"\\n"); '
                      'f.write(json.dumps({"type":"first_frame","ms":100*t})+"\\n")\'')
            out = folder / "out.json"
            result = report.external("x", out, host, viewer, None, 3, 10, 30, folder / "keep")
            self.assertTrue(result["ok"], result["errors"])
            self.assertEqual(starts.read_text().count("started"), 3)
            self.assertEqual(result["latency"]["key"]["p50_ms"], 22.0)
            self.assertEqual(result["motion"], {"kbps": 16.0, "fps": 20.0})
            self.assertEqual(result["extra"]["first_frame_ms"], 200.0)
            self.assertEqual(len(result["extra"]["takes"]), 3)
            self.assertTrue((folder / "keep" / "take-3" / "readback.jsonl").exists())
            self.assertEqual(json.loads(out.read_text())["latency"]["key"]["n"], 5)

    def test_external_host_never_ready_is_an_error_not_a_number(self):
        with tempfile.TemporaryDirectory() as name:
            out = Path(name) / "out.json"
            result = report.external("x", out, "exit 3", "true", None, 1, 5, 5, None)
            self.assertFalse(result["ok"])
            self.assertTrue(any("host not ready" in e for e in result["errors"]))
            self.assertIsNone(result["latency"]["key"]["p50_ms"])



if __name__ == "__main__":
    unittest.main()
