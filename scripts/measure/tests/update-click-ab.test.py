"""scripts/measure/update-click-ab.py: each update's metrics from run.py's timeline, and each side's medians."""
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("update_click_ab", HERE.parent / "update-click-ab.py")
uca = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uca)


def timeline(relaunch, home, wait=None):
    click_to = {"will_relaunch": relaunch}
    if wait is not None:
        click_to.update({"prewarm_wait_start": 100, "prewarm_wait_end.done": 100 + wait})
    return {"timeline": {"click_to": click_to, "click_to_v1_exit_ms": relaunch + 200,
                         "click_to_v2": {"process_start": relaunch + 400, "launch.first_window_frame_committed": relaunch + 900,
                                         "launch.home.first_page": None if home is None else relaunch + 400 + home}},
            "prewarm_log": ["launch pre-warm before install: done"] if wait is not None else []}


class UpdateClickAbTests(unittest.TestCase):
    def test_metrics_are_from_the_click_and_from_v2s_start(self):
        m = uca.metrics(timeline(3000, 1300, wait=800))
        self.assertEqual(m["click_to_relaunch"], 3000)
        self.assertEqual(m["prewarm_wait"], 800)
        self.assertEqual(m["v2_first_frame"], 500)
        self.assertEqual(m["v2_home_first_page"], 1300)
        self.assertEqual(m["click_to_home"], 4700)

    def test_prewarm_total_is_the_closing_lines_ms_in_all(self):
        result = timeline(3000, 1300)
        result["prewarm_log"] = ["launch pre-warm of 200: started", "launch pre-warm of 200: cmux exit 0 900 ms",
                                 "launch pre-warm of 200 (cmux.app): cmux exit 0 900 ms, cmux Helper exit 255 2100 ms; 2350 ms in all"]
        self.assertEqual(uca.metrics(result)["prewarm_total"], 2350)
        self.assertIsNone(uca.metrics(timeline(3000, 1300))["prewarm_total"], "a pre-warm the relaunch cut short has no total")

    def test_no_wait_and_no_home_page(self):
        m = uca.metrics(timeline(2000, None))
        self.assertEqual(m["prewarm_wait"], 0)
        self.assertIsNone(m["v2_home_first_page"])

    def test_medians_per_side(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for side, rounds in {"base": [(2000, 4000), (2100, 3800), (1900, None)],
                                 "head": [(3000, 1300, 900), (3100, 1250, 1000)]}.items():
                for i, args in enumerate(rounds, 1):
                    (out / f"run-{side}-{i}").mkdir()
                    (out / f"run-{side}-{i}" / "timeline.json").write_text(json.dumps(timeline(*args)))
            with redirect_stdout(io.StringIO()) as printed:
                uca.main(out)
            medians = json.loads((out / "medians.json").read_text())
        self.assertEqual(medians["base"]["n"], 3)
        self.assertEqual(medians["base"]["click_to_relaunch"], 2000)
        self.assertEqual(medians["base"]["v2_home_first_page"], 3900)
        self.assertEqual(medians["head"]["prewarm_wait"], 950)
        self.assertIn("UCA-MEDIAN head", printed.getvalue())
        self.assertEqual(medians["base"]["click_to_relaunch_p95"], 2100, "p95 of three updates is the slowest")
        self.assertEqual(medians["head"]["click_to_v2_frame_p95"], 4000)

    def test_phases_from_the_click(self):
        result = timeline(3000, 1300)
        result["timeline"]["click_to"].update({"windows_hidden.2": 40, "will_terminate": 3100})
        result["timeline"]["click_to_v2"].update({"launch.sidebar_rows_shown": 4100, "launch.launch_snapshot_shown": 3950,
                                                  "launch.daemon_snapshot_loaded": 4050})
        m = uca.metrics(result)
        self.assertEqual((m["windows_hidden"], m["will_terminate"], m["v2_process_start"]), (40, 3100, 3400))
        self.assertEqual((m["click_to_v2_frame"], m["click_to_restored"]), (3900, 4100))
        self.assertIsNone(uca.metrics(timeline(3000, 1300))["click_to_restored"], "restored needs all three marks")

    def test_frames_verdicts_are_counted(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for i, bad in enumerate([True, False], 1):
                run = out / f"run-head-{i}"
                run.mkdir()
                (run / "timeline.json").write_text(json.dumps(timeline(3000, 1300)))
                (run / "frames-verdict.json").write_text(json.dumps({"transition_frames": bad, "windows": {}, "content": {}}))
            with redirect_stdout(io.StringIO()):
                uca.main(out)
            medians = json.loads((out / "medians.json").read_text())
        self.assertEqual((medians["head"]["updates_with_transition_frames"], medians["head"]["updates_judged"]), (1, 2))


if __name__ == "__main__":
    unittest.main()
