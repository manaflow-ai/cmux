#!/usr/bin/env python3
"""An OCR miss backed by the daemon (lead 11:1xZ): no app, no fleet.

    python3 scripts/journeys/test_ocr_unread.py

A frame_screen `shows` text that text recognition misreads is no failed step when a daemon check of the SAME step that
names that text passed (smoke_new_terminals, smoke_app_lines, smoke_daemon_lines) and the frame shows the text but for
one glyph read as a non-alphanumeric character: it is recorded as "OCR could not read it (daemon check passed)". With no such check, a failed one, a frame
that does not show the text (blank, another line), or a `lacks` text present, the miss stays a failed step.

The two real cases, with the one-glyph folds of 648e4e5dfa9 ("₩") and 959ac3054cb ("+") taken out, so the rule
alone must carry them: STATUS 5811 (job 4b39ae9a, round 2 on cmux18, step 17, check-64.png) and STATUS 6305 (job
fc4afadcd821, round 5 on cmux22, step 55, check-80.png).
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import driver as D  # noqa: E402

SPEC = json.loads((HERE / "journeys" / "dogfood" / "smoke-dogfood.json").read_text())
STEP = {i: s for i, s in enumerate(SPEC["steps"], 1)}

WON = {"step": 17, "nonce": "543646", "token": "w3-543646-42",
       "ocr": ["$ echo w3-543646-$((6*7))", "₩3-543646-42"]}
PLUS = {"step": 55, "nonce": "445843", "token": "t2-445843-42",
        "ocr": ["$ D", "S Ш", "0~0-0x+v:", "$ echo t2-445843-$((6*7))", "+2-445843-42", "Did you know?",
                "Command Palette", "Run any cmux action by typing", "its name.", "Try It", "196P", "a"]}
OLD_FOLD = {k: v for k, v in D.OCR_FOLD.items() if k not in (ord("₩"), ord("￦"), ord("+"))}


class Fake(D.Journey):
    """step_expect with scripted live checks and scripted OCR lines."""
    def __init__(self, out, nonce, ocr, live):
        self.out, self.checks, self.marks, self.evidence = Path(out), 0, {}, []
        self.vars = {"nonce": nonce}
        self.live = live
        lines = ocr
        self.app = type("A", (), {"snapshot": lambda _s, path: Path(path), "read_text": lambda _s, image: list(lines)})()

    def evaluate(self, name, want, cache):
        if name in self.live:
            return self.live[name], {}
        return super().evaluate(name, want, cache)


class OcrUnread(unittest.TestCase):
    def setUp(self):
        self.saved = (D.OCR_FOLD, D.FRAME_GRACE)
        D.OCR_FOLD, D.FRAME_GRACE = OLD_FOLD, 0.0
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        D.OCR_FOLD, D.FRAME_GRACE = self.saved
        self.tmp.cleanup()

    def expect(self, case, live, ocr=None, step=None):
        j = Fake(self.tmp.name, case["nonce"], case["ocr"] if ocr is None else ocr, live)
        step = dict(step or STEP[case["step"]], timeout=0)
        step.pop("since", None)
        try:
            j.step_expect(step)
            error = None
        except D.StepError as e:
            error = str(e)
        frame = next(r for r in j.evidence if r["check"] == "frame_screen")
        return error, frame

    def test_the_two_real_misreads_with_the_daemon_check_passed_are_no_failed_step(self):
        for case in (WON, PLUS):
            live = {"smoke_new_terminals": True, "smoke_app_lines": True, "smoke_key_window": True}
            error, frame = self.expect(case, live)
            self.assertIsNone(error, (case["step"], error))
            self.assertTrue(frame["pass"])
            note = frame["detail"]["ocr_unread"]
            self.assertTrue(note.startswith("OCR could not read it (daemon check passed)"), note)
            self.assertIn(case["token"], note)
            self.assertIn("smoke_new_terminals", note)

    def test_the_rule_needs_the_step_s_own_daemon_check_of_that_text_to_pass(self):
        # Step 17: smoke_new_terminals names w3; it failed -> the OCR miss is a failed step too.
        error, frame = self.expect(WON, {"smoke_new_terminals": False, "smoke_key_window": True})
        self.assertIn("frame_screen", error)
        self.assertFalse(frame["pass"])
        self.assertNotIn("ocr_unread", frame["detail"])
        # Step 55: smoke_app_lines alone names t2 and passed -> enough.
        error, _ = self.expect(PLUS, {"smoke_new_terminals": False, "smoke_app_lines": True, "smoke_key_window": True})
        self.assertNotIn("frame_screen", error or "")
        # A step with no daemon check of the text: the miss stays red.
        bare = {"do": "expect", "title": "x", "all": [{"smoke_key_window": {}}, {"frame_screen": {"shows": ["t2-${nonce}-42"]}}]}
        error, _ = self.expect(PLUS, {"smoke_key_window": True}, step=bare)
        self.assertIn("frame_screen", error)
        # A daemon check that names another text only does not back this one.
        other = {"do": "expect", "title": "x", "all": [{"smoke_daemon_lines": {"lines": ["t1-${nonce}-42"]}},
                                                        {"frame_screen": {"shows": ["t2-${nonce}-42"]}}]}
        error, _ = self.expect(PLUS, {"smoke_daemon_lines": True}, step=other)
        self.assertIn("frame_screen", error)

    def test_a_frame_that_does_not_show_the_text_stays_a_failed_step(self):
        live = {"smoke_new_terminals": True, "smoke_app_lines": True, "smoke_key_window": True}
        for name, ocr in {
            "blank frame": [],
            "only the echoed command": ["$ echo t2-445843-$((6*7))"],
            "two glyphs misread": ["+3-445843-42"],
            "another nonce": ["t2-445844-41"],
            "the sidebar only": ["Did you know?", "Command Palette"],
        }.items():
            error, frame = self.expect(PLUS, live, ocr=ocr)
            self.assertIn("frame_screen", error or "", name)
            self.assertFalse(frame["pass"], name)

    def test_another_line_of_the_same_run_is_never_taken_for_a_misread(self):
        # Review BLOCK of fe97166ee14: the journey's lines differ in one letter or digit, and the backing checks read
        # the model, not the pixels. A wrong tab, a wrong workspace or a blank second pane must stay red.
        for name, (n, nonce, ocr, live) in {
            "step 55: the window draws tab t1, not t2": (55, "445843", ["$ echo t1-445843-$((6*7))", "t1-445843-42"],
                {"smoke_new_terminals": True, "smoke_app_lines": True, "smoke_key_window": True}),
            "step 17: the window shows workspace w2, not w3": (17, "543646", ["$ echo w2-543646-$((6*7))", "w2-543646-42"],
                {"smoke_new_terminals": True, "smoke_key_window": True}),
            "step 23: the second new pane is blank, only d1 shows": (23, "111111", ["$ echo d1-111111-$((6*7))", "d1-111111-42"],
                {"smoke_panes": True, "smoke_new_terminals": True, "smoke_app_lines": True, "smoke_key_window": True}),
            "step 75: the window still shows w3, not w4": (75, "222222", ["$ echo w3-222222-$((6*7))", "w3-222222-42"],
                {"smoke_daemon_lines": True}),
        }.items():
            error, frame = self.expect({"step": n, "nonce": nonce, "ocr": ocr}, live)
            self.assertIn("frame_screen", error or "", name)
            self.assertFalse(frame["pass"], name)
            self.assertNotIn("ocr_unread", frame["detail"], name)

    def test_a_lacks_text_on_screen_is_never_excused(self):
        step = {"do": "expect", "title": "x", "all": [
            {"smoke_daemon_lines": {"lines": ["t2-${nonce}-42"]}},
            {"frame_screen": {"shows": ["t2-${nonce}-42"], "lacks": ["stale-${nonce}"]}}]}
        error, _ = self.expect(PLUS, {"smoke_daemon_lines": True}, ocr=PLUS["ocr"] + ["stale-445843"], step=step)
        self.assertIn("frame_screen", error)


class GateNote(unittest.TestCase):
    def test_the_gate_names_excused_frames_of_a_round(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("smoke_gate_ocr", HERE / "smoke-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory() as tmp:
            note = "OCR could not read it (daemon check passed): 't2-445843-42' read as '+2-445843-42', smoke_new_terminals passed"
            row = {"id": "smoke-dogfood", "status": "pass", "evidence": [
                {"check": "smoke_new_terminals", "pass": True, "detail": {}},
                {"check": "frame_screen", "pass": True, "detail": {"ocr_unread": note}},
                {"check": "frame_screen", "pass": True, "detail": "not a dict"}]}
            (Path(tmp) / "results.jsonl").write_text(json.dumps(row) + "\n")
            self.assertEqual(gate.ocr_unread(Path(tmp)), [note])
            (Path(tmp) / "results.jsonl").write_text("not json\n")
            self.assertEqual(gate.ocr_unread(Path(tmp)), [])
        self.assertEqual(gate.ocr_unread(Path("/nonexistent-rv")), [])


if __name__ == "__main__":
    unittest.main()
