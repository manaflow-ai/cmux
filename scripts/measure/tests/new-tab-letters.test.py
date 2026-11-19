#!/usr/bin/env python3
"""scripts/measure/new-tab-letters.py: the 3 keys as steps, the cut of the hold's log, a case's verdict, a form's word.

What these rows hold: each key-down of the 3 keys is 30 ms after the key-down before it, and the letter goes down
with no Command; the notes of a case are the notes after the read before it, also when the log's ring lost its
oldest notes; a case is a `chord` case only when the hold ended at the second New Tab key with keys and no report
of the page before it; the rule (`dropped 0` and the letter in the field; `dropped 1` and no letter for from-chat); a
form with too few chord cases is NOT PROVED; a case's steps against a model app, and a case whose setup fails is
`not_run` and closes its workspace.

No app: the app is a small model of the calls that a case makes. So this proves the tool's own logic, NOT that the
app drops or keeps a letter, and NOT that a key of a sequence reaches a page.
Run: python3 -I scripts/measure/tests/new-tab-letters.test.py"""
import importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("new_tab_letters_under_test", os.path.join(HERE, "..", "new-tab-letters.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

CHORD = ["begin page opened=a +0ms", "hold key #1 +30ms", "release: chord, keys to page +60ms", "begin page opened=b +61ms",
         "ready match +90ms", "drained to field +91ms"]
READY = ["begin page opened=a +0ms", "ready match +12ms", "drained to field +13ms", "begin page opened=b +61ms"]
DROP = CHORD[:3] + ["dropped 1 keys (chord): what had the keyboard at the opening still has it +60ms"] + CHORD[3:]


def downs(steps):
    at, found = 0.0, []
    for step in steps:
        at += step.get("after_ms") or 0
        if step["down"]:
            found.append((step["key_code"], at))
    return found


class Steps(unittest.TestCase):
    def test_each_key_down_is_30_ms_after_the_one_before(self):
        keys = [(code, at) for code, at in downs(M.three_keys()) if code in (M.T, M.X)]
        self.assertEqual([code for code, _ in keys], [M.T, M.X, M.T])
        self.assertEqual([at - keys[0][1] for _, at in keys], [0.0, 30.0, 60.0])

    def test_the_letter_goes_down_with_no_command(self):
        held = False
        for step in M.three_keys():
            if step["key_code"] == M.CMD:
                held = step["down"]
            if step["key_code"] == M.X:
                self.assertFalse(held)
            if step["key_code"] == M.T:
                self.assertTrue(held)

    def test_the_guard_form_has_one_new_tab_key(self):
        self.assertEqual([code for code, _ in downs(M.three_keys(second=False)) if code == M.T], [M.T])

    def test_a_switch_key_has_shift_and_the_3_keys_come_after_the_wait(self):
        steps = M.chord(M.NEXT_TAB, shift=True) + M.three_keys(M.SWITCH_WAIT_MS)
        found = downs(steps)
        self.assertEqual([code for code, _ in found][:3], [M.CMD, M.SHIFT, M.NEXT_TAB])
        self.assertEqual(found[3], (M.CMD, 12.0 + M.SWITCH_WAIT_MS))


class Notes(unittest.TestCase):
    def test_the_notes_after_the_read_before(self):
        self.assertEqual(M.new_notes(["a", "b"], ["a", "b", "c", "d"]), ["c", "d"])
        self.assertEqual(M.new_notes(["a", "b"], ["a", "b"]), [])
        self.assertEqual(M.new_notes([], ["c"]), ["c"])

    def test_a_ring_that_lost_its_oldest_notes(self):
        self.assertEqual(M.new_notes(["a", "b", "c"], ["b", "c", "d"]), ["d"])
        self.assertEqual(M.new_notes(["a", "b", "c"], ["x", "y", "z"]), ["x", "y", "z"])


class Judge(unittest.TestCase):
    def test_a_chord_case_with_the_letter(self):
        self.assertEqual(M.judge("three-key", CHORD, "x"),
                         {"chord": True, "dropped": 0, "want_dropped": 0, "letter_in_field": True, "pass": True})

    def test_a_dropped_letter_fails(self):
        found = M.judge("reselect", DROP, "")
        self.assertEqual((found["chord"], found["dropped"], found["pass"]), (True, 1, False))

    def test_the_form_from_a_chat_wants_the_drop(self):
        self.assertTrue(M.judge("from-chat", DROP, "")["pass"])
        self.assertFalse(M.judge("from-chat", CHORD, "x")["pass"])

    def test_a_ready_case_wants_the_letter_in_each_form(self):
        for form in ("three-key", "from-chat"):
            found = M.judge(form, READY, "x")
            self.assertEqual((found["chord"], found["want_dropped"], found["pass"]), (False, 0, True))
        self.assertFalse(M.judge("three-key", READY, "")["pass"])

    def test_a_chord_with_no_keys_is_no_chord_case(self):
        self.assertFalse(M.judge("three-key", ["release: chord, no keys to page +60ms"], "x")["chord"])

    def test_no_read_of_the_field_is_no_pass(self):
        found = M.judge("three-key", CHORD, None)
        self.assertEqual((found["letter_in_field"], found["pass"]), (None, False))


class Verdict(unittest.TestCase):
    def cases(self, chords, readies, form="three-key"):
        return [M.judge(form, CHORD, "x") for _ in range(chords)] + [M.judge(form, READY, "x") for _ in range(readies)]

    def test_a_form_with_enough_chord_cases_passes(self):
        found = M.verdict("three-key", self.cases(6, 6))
        self.assertEqual((found["verdict"], found["chord"], found["chord_pass"], found["ready"], found["ready_pass"]), ("PASS", 6, 6, 6, 6))

    def test_too_few_chord_cases(self):
        self.assertEqual(M.verdict("three-key", self.cases(5, 7))["verdict"], M.NOT_PROVED)

    def test_the_guard_form_needs_no_chord_case(self):
        self.assertEqual(M.verdict("two-key", self.cases(0, 12, "two-key"))["verdict"], "PASS")

    def test_one_failed_case_or_one_case_not_run_fails(self):
        self.assertEqual(M.verdict("three-key", self.cases(11, 0) + [M.judge("three-key", DROP, "")])["verdict"], "FAIL")
        self.assertEqual(M.verdict("three-key", self.cases(11, 0) + [{"not_run": "why"}])["verdict"], "FAIL")
        self.assertEqual(M.verdict("three-key", [{"not_run": "why"}])["verdict"], "NOT RUN")


class Builder:
    """A model of the session helper: one pane, tabs with ids, the script's actions that a case sends."""

    def __init__(self):
        self.tabs_of, self.selected, self.actions, self.chat_fallbacks, self.count = {"p": ["first"]}, "first", [], 0, 0

    def new_workspace(self):
        return "w"

    def show(self, workspace):
        pass

    def workspace(self, workspace):
        return {"id": workspace}

    def panes(self, workspace):
        return [{"id": "p"}]

    def focus_pane(self, pane):
        pass

    def tabs(self, workspace, pane):
        return [{"id": tab, "selected": tab == self.selected} for tab in self.tabs_of[pane]]

    def settled_tabs(self, workspace, pane, seconds=20):
        return self.tabs(workspace, pane)

    def add(self):
        self.count += 1
        self.tabs_of["p"].append(f"t{self.count}")
        self.selected = f"t{self.count}"

    def action(self, name, args=None, target=None, focus=True):
        self.actions.append((name, target))
        if name == "newTab.page":
            self.add()
        if name == "tab.focus":
            self.selected = target.split(":", 1)[1]


class App:
    """A model of the app's calls: a sequence makes a tab for each New Tab key and writes the hold's notes."""

    def __init__(self, builder, notes, texts, refuse=None):
        self.builder, self.notes, self.texts, self.refuse, self.log, self.sequences = builder, notes, texts, refuse, ["old +0ms"], []

    def __call__(self, method, params=None):
        params = params or {}
        if method == "debug.key":
            if self.refuse:
                return {"error": self.refuse}
            self.sequences.append(params)
            if [step["key_code"] for step in params["sequence"] if step["down"]] == [M.X]:
                self.texts[self.builder.selected] = "x"  # a letter alone goes to the field of the shown tab
            for step in params["sequence"]:
                if step["key_code"] == M.T and step["down"]:
                    self.builder.add()
            self.log = self.log + self.notes
            return {"scheduled": len(params["sequence"]), "key_window": params["key_window"]}
        if method == "debug.focus":
            return {"new_tab_key_log": list(self.log)}
        if method == "debug.new_tab" and params.get("action") == "field":
            return {"text": self.texts.get(self.builder.selected, "")}
        if method == "debug.new_tab":
            return {"openings": [{"spare": False, "idle": True, "ms": 1.0}, {"spare": True, "idle": False, "ms": 1.0}]}
        return {}


def wait(predicate, seconds, step=0.25):
    return predicate() or None


class Case(unittest.TestCase):
    def letters(self, notes, texts, refuse=None):
        builder = Builder()
        app = App(builder, notes, texts, refuse)
        return M.Letters(builder, app, wait, pause=lambda seconds: None), builder, app

    def test_the_3_keys_in_the_page_window_and_the_first_new_tabs_field(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"})
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record["tabs_made"], record["field"]),
                         (None, True, True, 2, "x"))
        self.assertEqual(record["notes"], CHORD)
        self.assertEqual((app.sequences[0]["key_window"], app.sequences[0]["pane"]), ("page", "p"))
        self.assertEqual(record["openings"], [{"spare": False, "idle": True}, {"spare": True, "idle": False}])
        self.assertIn(("tab.focus", "tab:t2"), builder.actions)
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_the_reselect_form_selects_the_2_tabs_before_the_3_keys(self):
        letters, builder, app = self.letters(CHORD, {"t3": "x"})
        record = letters.case("reselect", 0)
        self.assertTrue(record["pass"], record)
        self.assertEqual([action for action in builder.actions if action[0] == "tab.focus"][:2], [("tab.focus", "tab:t1"), ("tab.focus", "tab:t2")])
        self.assertEqual(len(app.sequences), 2)

    def test_a_switch_form_records_the_2_fields_of_its_setup_and_sends_the_switch_key(self):
        letters, builder, app = self.letters(CHORD, {"t3": "x"})
        record = letters.case("switch-previous", 0)
        self.assertEqual((record.get("not_run"), record["setup_fields"], record["tabs_made"]), (None, ["x", "x"], 2))
        last = [step["key_code"] for step in app.sequences[-1]["sequence"] if step["down"]]
        self.assertEqual(last[:3], [M.CMD, M.SHIFT, M.PREVIOUS_TAB])
        self.assertEqual(M.judge("switch-previous", record["notes"], record["field"])["pass"], record["pass"])

    def test_a_refused_sequence_is_a_case_not_run_and_the_workspace_is_closed(self):
        letters, builder, _ = self.letters(CHORD, {}, refuse="no Chromium page window for pane p")
        record = letters.case("three-key", 0)
        self.assertIn("refused the sequence", record["not_run"])
        self.assertNotIn("pass", record)
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_run_gives_each_forms_word(self):
        letters, _, _ = self.letters(CHORD, {"t2": "x"})
        said = []
        report = letters.run(1, forms=("three-key",), say=said.append)
        self.assertEqual((report["forms"][0]["verdict"], report["forms"][0]["chord"], len(report["cases"])), ("PASS", 1, 1))
        self.assertEqual(len(said), 2)

    def test_a_case_after_the_budget_is_not_run(self):
        letters, builder, _ = self.letters(CHORD, {"t2": "x"})
        clock = iter([0.0, 1.0, 11.0, 12.0])
        report = letters.run(3, forms=("three-key",), say=lambda line: None, budget_s=10.0, now=lambda: next(clock))
        self.assertEqual([("not_run" in case) for case in report["cases"]], [False, True, True])
        self.assertIn("budget", report["cases"][1]["not_run"])
        self.assertEqual((report["forms"][0]["verdict"], report["forms"][0]["ran"], report["forms"][0]["not_run"]), (M.NOT_PROVED, 1, 2))
        self.assertEqual(len([action for action in builder.actions if action[0] == "closeWorkspace"]), 1)


if __name__ == "__main__":
    unittest.main()
