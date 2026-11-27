"""Owed numbers (eval.py OWED): a requested target that did not bring its OCR error, encoder skips or
budget bits per pixel fails the run, and the last line names the target and the field."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("screen_eval_owed", HERE / "eval.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def rd_target(*, cer=0.01, ready=True, skips=(0, 0, 0), budget=(0.06, 0.07, 0.06), owes=("ocr", "skips", "budget-bpp")):
    t = report.empty_target([])
    t["ok"] = True
    t["owes"] = list(owes)
    t["ocr"] = {**t["ocr"], "cer": cer, "comparison_ready": ready}
    t["extra"]["repeats"] = [
        {"repeat": i + 1, "window_netem_metrics": {"skips": s, "budget_bits_per_pixel_min": b}}
        for i, (s, b) in enumerate(zip(skips, budget))]
    return t


def run_owed(targets: dict) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "results.json"
        path.write_text(json.dumps({"schema": report.SCHEMA, "targets": targets}))
        return subprocess.run([sys.executable, "-I", str(HERE / "eval.py"), "owed", str(path)],
                              capture_output=True, text=True, check=False)


class OwedTests(unittest.TestCase):
    def test_a_complete_run_owes_nothing(self):
        p = run_owed({"rd-ladder": rd_target(), "apple-high": rd_target(owes=["ocr"], skips=(), budget=())})
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(p.stdout, "")

    def test_the_quality_ladder_run_that_read_null_fails_naming_each_field(self):
        # cmuxterm-hq quality-ladder/runs/2026-11-26T1806Z: apple-high's scene never started,
        # rd-ladder's calibration did not hold at cer 0.03, and no repeat had the budget.
        apple = report.empty_target(["scene 1 exited 3 (scene: no GO_FILE within 120 s)"])
        apple["owes"] = ["ocr"]
        ladder = rd_target(cer=0.03, ready=False, budget=(None, None, None))
        p = run_owed({"apple-high": apple, "rd-ladder": ladder})
        self.assertEqual(p.returncode, 6)
        lines = p.stdout.strip().splitlines()
        self.assertIn("SCREEN-STREAM-EVAL-MISSING apple-high: ocr error (scene 1 exited 3 (scene: no GO_FILE within 120 s))", lines)
        self.assertIn("SCREEN-STREAM-EVAL-MISSING rd-ladder: ocr error (calibration did not hold, cer 0.03), budget bpp", lines)
        self.assertEqual(lines[-1], "screen-stream-eval: owed numbers missing, apple-high: ocr error; "
                                    "rd-ladder: ocr error (calibration did not hold, cer 0.03), budget bpp")

    def test_one_repeat_without_skips_or_budget_is_missing(self):
        t = rd_target(skips=(0, None, 0), budget=(0.06, 0.06, float("nan")))
        self.assertEqual(report.missing_fields(t), ["encoder skips", "budget bpp"])
        self.assertEqual(report.missing_fields(rd_target(skips=(), budget=())), ["encoder skips", "budget bpp"])
        self.assertEqual(report.missing_fields(rd_target(skips=(True, 0, 0))), ["encoder skips"])

    def test_a_target_that_owes_nothing_is_never_named(self):
        t = report.empty_target(["build failed (build.log)"])
        self.assertEqual(report.missing_fields(t), [])
        self.assertEqual(run_owed({"webrtc": t}).returncode, 0)

    def test_target_json_keeps_what_the_harness_wrote_before_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "repeats-requested.json").write_text('{"count":3}')
            (folder / "owes").write_text("ocr\nskips\n")
            (folder / "errors.txt").write_text("build failed (build.log)\n")
            report.target("rd", folder, folder / "target.json")
            t = json.loads((folder / "target.json").read_text())
        self.assertEqual(t["owes"], ["ocr", "skips"])
        self.assertEqual(report.missing_fields(t), ["ocr error", "encoder skips"])

    def test_each_target_names_what_it_owes(self):
        env = {**os.environ, "EVAL_ROOT": "/nonexistent", "EVAL_BIN": "/nonexistent"}
        env.pop("EVAL_RD_HOST_FLAGS", None)
        expected = {"rd": ["owes-ocr", "owes-skips"],
                    "rd-ladder": ["owes-ocr", "owes-skips", "owes-budget-bpp"],
                    "rd-ladder-1000": ["owes-ocr", "owes-skips", "owes-budget-bpp"],
                    "apple-high": ["owes-ocr"], "apple-standard": ["owes-ocr"]}
        for name, owes in expected.items():
            p = subprocess.run(["bash", str(HERE / "targets" / f"{name}.sh"), "caps"],
                               capture_output=True, text=True, env=env, check=False)
            self.assertEqual(p.returncode, 0, (name, p.stderr))
            self.assertEqual([c for c in p.stdout.split() if c.startswith("owes-")], owes, name)

    def test_the_harness_exits_6_after_writing_results(self):
        script = (HERE.parent / "screen-stream-eval.sh").read_text()
        tail = script[script.rindex("finish\n"):]
        self.assertLess(tail.index("owed\n"), tail.index("exit 6"))
        self.assertIn('sed -n \'s/^owes-//p\' <<<"$caps" >"$dir/owes"', script)
        self.assertLess(script.index('>"$dir/owes"'), script.index('SCREEN-STREAM-EVAL-STAGE $name build'))


if __name__ == "__main__":
    unittest.main()
