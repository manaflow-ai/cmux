#!/usr/bin/env python3
"""scripts/measure/new-tab-letters.py: the 3 keys as steps, the cut of the hold's log, a case's verdict, a form's word.

What these rows hold: each key-down of the 3 keys is 30 ms after the key-down before it, and the letter goes down
with no Command; the notes of a case are the notes after the read before it, also when the log's ring lost its
oldest notes; a case is a `chord` case only when the hold ended at the second New Tab key with keys and no report
of the page before it; the rule (`dropped 0` and the field is the letter; `dropped 1` and an empty field for
from-chat); a form with too few chord cases is NOT PROVED; a case's steps against a model app, and a case whose setup
fails is `not_run` and closes its workspace; a close-move case keeps the app's notes of the close, a case whose close
did not move is counted apart, and the form with too few cases in a move is NOT PROVED; a case with no note of a
hold's start is `not_run`; a switch case whose setup letters did not get to their fields is `not_run`; each printed
line is JSON after its name; the words for a run in which no case ran; the tab that a pane shows is the pane's
`selected_tab` of the snapshot (no key of a tab), else the focus model's word; a select that the pane shows late is
waited for, and one that it never shows is `not_run` with the shown tab and the app's refusal, in a setup too.

No app: the app is a small model of the calls that a case makes. So this proves the tool's own logic, NOT that the
app drops or keeps a letter, NOT that a key of a sequence reaches a page, NOT that the app writes the notes of a
close in the words of the model (they are copied from the app's source), and NOT that the app's snapshot has the
keys of the model (they are copied from the app's source too: ControlTopology+JSON.swift, DebugFocus.swift).
Run: python3 -I scripts/measure/tests/new-tab-letters.test.py"""
import importlib.util, json, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("new_tab_letters_under_test", os.path.join(HERE, "..", "new-tab-letters.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

CHORD = ["begin page opened=a +0ms", "hold key #1 +30ms", "release: chord, keys to page +60ms", "begin page opened=b +61ms",
         "ready match +90ms", "drained to field +91ms"]
READY = ["begin page opened=a +0ms", "ready match +12ms", "drained to field +13ms", "begin page opened=b +61ms"]
DROP = CHORD[:3] + ["dropped 1 keys (chord): what had the keyboard at the opening still has it +60ms"] + CHORD[3:]
# What `debug.motion` says at its stop for a close, in the words of the app's source (PaneCommitMotion.swift).
MOVE = {"pane_animations": True, "reduce_motion": False, "spans": [{"name": "pane.close", "ms": 250.0}],
        "notes": [{"t_ms": 2.0, "text": "a note of another part"}, {"t_ms": 3.0, "text": "layout.commit: close moves 1 panes for 0.25 s"}]}
ONE_FRAME = {"pane_animations": True, "reduce_motion": False, "spans": [],
             "notes": [{"t_ms": 3.0, "text": "layout.commit: close in one frame (the panes move at a commit: false)"}]}


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

    def test_the_field_is_the_letter_and_no_more(self):
        # A letter that came 2 times, or with another character, is in the field and is no pass.
        for text in ("xx", "xt", " x"):
            found = M.judge("three-key", CHORD, text)
            self.assertEqual((found["letter_in_field"], found["pass"]), (True, False), text)
        self.assertFalse(M.judge("from-chat", DROP, "t")["pass"])  # the drop wants an empty field, not a field with no x


class Verdict(unittest.TestCase):
    def cases(self, chords, readies, form="three-key"):
        return [M.judge(form, CHORD, "x") for _ in range(chords)] + [M.judge(form, READY, "x") for _ in range(readies)]

    def closes(self, moves, plain):
        """Cases of close-move that each pass with a chord: `moves` in a move of the close, `plain` with no move."""
        return [{**M.judge("close-move", CHORD, "x"), "moved": index < moves} for index in range(moves + plain)]

    def test_a_close_with_no_move_is_counted_apart_and_too_few_moves_is_not_proved(self):
        found = M.verdict("close-move", self.closes(0, 12))  # each close in one frame: the form is the plain close of a pane
        self.assertEqual((found["verdict"], found["chord_pass"]), ("NOT PROVED: too few cases in a close's move", 12))
        self.assertEqual((found.get("move"), found.get("no_move")), (0, 12))
        self.assertEqual(M.verdict("close-move", self.closes(5, 7))["verdict"], M.NO_MOVE)
        found = M.verdict("close-move", self.closes(6, 6))
        self.assertEqual((found["verdict"], found.get("move"), found.get("no_move")), ("PASS", 6, 6))
        self.assertTrue(M.NO_MOVE.startswith("NOT PROVED") and M.NO_MOVE != M.NOT_PROVED)

    def test_a_failed_close_case_fails_with_no_move_too_and_no_other_form_counts_moves(self):
        self.assertEqual(M.verdict("close-move", self.closes(0, 11) + [{**M.judge("close-move", DROP, ""), "moved": False}])["verdict"], "FAIL")
        self.assertNotIn("move", M.verdict("three-key", self.cases(6, 6)))

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


class Order(unittest.TestCase):
    def test_the_guard_form_is_the_last_of_a_run_and_each_form_is_one_time_in_it(self):
        self.assertEqual((M.FORMS[0], M.FORMS[-1], len(set(M.FORMS))), ("reselect", "two-key", 7))
        self.assertEqual(M.NO_CHORD, ("two-key",))


class Builder:
    """A model of the session helper: panes (one at the start) with tabs that have ids, the script's actions that a
    case sends. `selected` is the tab that the pane with the keyboard shows. A pane and a tab have the keys of the
    app's snapshot (ControlTopology+JSON.swift): the pane names its shown tab in `selected_tab`, and a tab of the
    daemon has NO key `selected`. `late`: a select shows its tab only after that many reads of the panes. `refuse`:
    what the app says to a select that it does not do. `store`: False when the snapshot names no shown tab."""

    def __init__(self, late=0, refuse=None, store=True):
        self.tabs_of, self.shown, self.focused = {"p": ["first"]}, {"p": "first"}, "p"
        self.actions, self.chat_fallbacks, self.count = [], 0, 0
        self.late, self.refuse, self.store, self.coming = late, refuse, store, None

    @property
    def selected(self):
        return self.shown.get(self.focused)

    def new_workspace(self):
        return "w"

    def show(self, workspace):
        pass

    def workspace(self, workspace):
        return {"id": workspace}

    def panes(self, workspace):
        if self.coming:  # a select that the pane shows late: one read of the panes nearer
            self.coming[2] -= 1
            if self.coming[2] < 0:
                self.shown[self.coming[0]], self.coming = self.coming[1], None
        return [{"id": pane, "selected_tab": self.shown.get(pane) if self.store else None, "tabs": self.tabs(workspace, pane)}
                for pane in self.tabs_of]

    def focus_pane(self, pane):
        self.focused = pane

    def tabs(self, workspace, pane):
        return [{"id": tab, "kind": "page"} for tab in self.tabs_of.get(pane, [])]

    def settled_tabs(self, workspace, pane, seconds=20):
        return self.tabs(workspace, pane)

    def add(self, pane=None):
        """A new tab in `pane` (None: the pane with the keyboard), which then shows it."""
        pane = pane or self.focused
        self.count += 1
        self.tabs_of[pane].append(f"t{self.count}")
        self.shown[pane] = f"t{self.count}"

    def add_tab(self, workspace, pane, kind):
        self.actions.append((f"add_tab {kind}", f"pane:{pane}"))
        self.add(pane)

    def split(self, workspace, pane, how):
        self.tabs_of["q"], self.shown["q"] = ["came"], "came"
        return "q"

    def close(self, tab):
        """The tab goes; a pane with no tab goes too, and the first pane then has the keyboard."""
        pane = next(pane for pane, tabs in self.tabs_of.items() if tab in tabs)
        self.tabs_of[pane].remove(tab)
        self.shown[pane] = self.tabs_of[pane][-1] if self.tabs_of[pane] else None
        if not self.tabs_of[pane]:
            del self.tabs_of[pane], self.shown[pane]
            self.focused = "p"

    def action(self, name, args=None, target=None, focus=True):
        self.actions.append((name, target))
        if name == "newTab.page":
            self.add(target.split(":", 1)[1])
        if name == "tab.focus":
            tab = target.split(":", 1)[1]
            pane = next(pane for pane, tabs in self.tabs_of.items() if tab in tabs)
            if self.refuse:
                return {"error": self.refuse}
            if self.late:
                self.coming = [pane, tab, self.late]
            else:
                self.shown[pane] = tab
        if name == "closeTab":
            self.close(target.split(":", 1)[1])
        return {}


class App:
    """A model of the app's calls: a sequence makes a tab for each New Tab key, closes the shown tab at a Close Tab
    key, and writes the hold's notes. `motion`: what `debug.motion` says at its stop. `deaf`: a letter of a setup
    does not get to its field. `focus`: `debug.focus` has the focus model's word on each pane (DebugFocus.swift)."""

    def __init__(self, builder, notes, texts, refuse=None, motion=None, deaf=False, focus=False):
        self.builder, self.notes, self.texts, self.refuse, self.log, self.sequences = builder, notes, texts, refuse, ["old +0ms"], []
        self.motion, self.deaf, self.calls, self.focus = motion, deaf, [], focus

    def __call__(self, method, params=None):
        params = params or {}
        self.calls.append((method, params.get("action")))
        if method == "debug.key":
            if self.refuse:
                return {"error": self.refuse}
            self.sequences.append(params)
            if [step["key_code"] for step in params["sequence"] if step["down"]] == [M.X] and not self.deaf:
                self.texts[self.builder.selected] = "x"  # a letter alone goes to the field of the shown tab
            for step in params["sequence"]:
                if step["key_code"] == M.W and step["down"]:
                    self.builder.close(self.builder.selected)
                if step["key_code"] == M.T and step["down"]:
                    self.builder.add()
            self.log = self.log + self.notes
            return {"scheduled": len(params["sequence"]), "key_window": params["key_window"]}
        if method == "debug.focus":
            panes = [{"pane": pane, "selected": shown, "tabs": [f"{tab}:page" for tab in self.builder.tabs_of[pane]]}
                     for pane, shown in self.builder.shown.items()]
            return {"new_tab_key_log": list(self.log), **({"windows": [{"topology": panes}]} if self.focus else {})}
        if method == "debug.new_tab" and params.get("action") == "field":
            return {"text": self.texts.get(self.builder.selected, "")}
        if method == "debug.new_tab":  # an opening as the app gives it (DebugNewTab.swift): no key `idle`
            return {"openings": [{"spare": False, "cross_window": False, "refit": False, "ms": 1.0},
                                 {"spare": True, "cross_window": False, "refit": True, "ms": 1.0}]}
        if method == "debug.agent_pane":
            return {"focused": True}
        if method == "debug.motion" and params.get("action") == "stop":
            return self.motion
        return {}


def wait(predicate, seconds, step=0.25):
    return predicate() or None


def poll(predicate, seconds, step=0.25):
    """The helper's wait with no sleep: one read for each step of the time, to the first read that is true."""
    return next((found for found in (predicate() for _ in range(max(1, round(seconds / step)))) if found), None)


class Case(unittest.TestCase):
    def letters(self, notes, texts, refuse=None, builder=None, wait=wait, **model):
        builder = builder or Builder()
        app = App(builder, notes, texts, refuse, **model)
        return M.Letters(builder, app, wait, pause=lambda seconds: None), builder, app

    def test_the_shown_tab_is_the_panes_selected_tab_and_no_key_of_a_tab(self):
        # The app's snapshot: a pane has `selected_tab`, and a tab of the daemon has no key `selected`. A tool that
        # wants `selected` in a tab finds no shown tab in any pane: then each case of each form is `not_run`.
        letters, builder, _ = self.letters(CHORD, {"t2": "x"})
        self.assertEqual([sorted(pane) for pane in builder.panes({"id": "w"})], [["id", "selected_tab", "tabs"]])
        self.assertNotIn("selected", builder.tabs("w", "p")[0])
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record.get("pass"), record.get("field")), (None, True, "x"))
        self.assertEqual(letters.shown("w", "p"), "t2")

    def test_a_select_that_the_pane_shows_late_is_waited_for(self):
        letters, builder, _ = self.letters(CHORD, {"t2": "x"}, builder=Builder(late=3), wait=poll)
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record.get("pass"), record.get("field")), (None, True, "x"))
        self.assertIsNone(builder.coming)

    def test_a_select_that_the_pane_never_shows_is_not_run_with_the_shown_tab_and_the_apps_word(self):
        letters, builder, _ = self.letters(CHORD, {"t2": "x"}, builder=Builder(refuse="No tab matches t2"), wait=poll)
        record = letters.case("three-key", 0)
        self.assertEqual(record.get("not_run"), "the pane shows the tab t3, not the tab t2, after its select: the app said: No tab matches t2")
        self.assertNotIn("pass", record)
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_a_select_of_a_setup_that_the_pane_does_not_show_is_not_run_before_the_cases_keys(self):
        # switch-next selects its first tab before the keys: with no such select the case would be switch-previous'.
        letters, builder, app = self.letters(CHORD, {"t3": "x"}, builder=Builder(refuse="no"))
        record = letters.case("switch-next", 0)
        self.assertEqual(record.get("not_run"), "the pane shows the tab t2, not the tab t1, after its select: the app said: no")
        self.assertEqual(len(app.sequences), 2)  # the 2 letters of the setup, and no key of the case

    def test_the_focus_models_word_is_the_shown_tab_when_the_snapshot_names_none(self):
        letters, builder, _ = self.letters(CHORD, {"t2": "x"}, builder=Builder(store=False), focus=True)
        self.assertEqual(builder.panes({"id": "w"})[0]["selected_tab"], None)
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record.get("pass")), (None, True))
        # With no word of the snapshot and none of the focus model, the tool knows no shown tab: `not_run`.
        letters, _, _ = self.letters(CHORD, {"t2": "x"}, builder=Builder(store=False))
        self.assertEqual(letters.case("three-key", 0).get("not_run"), "the pane shows no tab that the app names, not the tab t2, after its select")

    def test_the_3_keys_in_the_page_window_and_the_first_new_tabs_field(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"})
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record["tabs_made"], record["field"]),
                         (None, True, True, 2, "x"))
        self.assertEqual(record["notes"], CHORD)
        self.assertEqual((app.sequences[0]["key_window"], app.sequences[0]["pane"]), ("page", "p"))
        # The keys of an opening that the app gave, and no key that it did not give (its time is not in the record).
        self.assertEqual(record["openings"], [{"spare": False, "cross_window": False, "refit": False},
                                              {"spare": True, "cross_window": False, "refit": True}])
        self.assertNotIn("moved", record)
        self.assertNotIn(("debug.motion", "start"), app.calls)
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
        self.assertEqual((record["pass"], record["chord"], record["field"]), (True, True, "x"))
        self.assertEqual(len(app.sequences), 3)  # a letter for each of the 2 tabs, then the switch key with the 3 keys

    def test_a_switch_form_whose_setup_letters_did_not_get_to_their_fields_is_not_run(self):
        # The first new tab has the letter, so the case would pass: but its 2 tabs are untouched, and that is the
        # form three-key, not a switch between 2 tabs that each have a letter.
        for form in ("switch-next", "switch-previous"):
            letters, builder, app = self.letters(CHORD, {"t3": "x"}, deaf=True)
            record = letters.case(form, 0)
            self.assertIn("did not get to its field", record.get("not_run", ""), record)
            self.assertEqual((record["setup_fields"], "pass" in record, len(app.sequences)), (["", ""], False, 2))
            self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_a_case_with_no_note_of_a_holds_start_is_not_run(self):
        # The log gave no note for the case's keys (the app wrote none, or the read failed): `dropped 0` of an empty
        # log is no read of what the hold did, and the letter in the field does not make it a pass.
        letters, builder, app = self.letters([], {"t2": "x"})
        record = letters.case("three-key", 0)
        self.assertIn("no note of a hold's start", record.get("not_run", ""), record)
        self.assertEqual((record["notes"], record["tabs_made"], "pass" in record), ([], 2, False))
        self.assertEqual(M.verdict("three-key", [record])["verdict"], "NOT RUN")
        # Notes of another kind only (a release with no start of a hold) are no read too.
        letters, _, _ = self.letters(["release: limit, no keys to page +250ms"], {"t2": "x"})
        self.assertIn("not_run", letters.case("three-key", 0))

    def test_the_form_from_a_chat_opens_a_chat_gives_its_field_the_keyboard_and_wants_the_drop(self):
        letters, builder, app = self.letters(DROP, {})
        record = letters.case("from-chat", 0)
        self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record["dropped"], record["field"]), (None, True, True, 1, ""))
        self.assertIn(("add_tab chat", "pane:p"), builder.actions)
        self.assertIn(("tab.focus", "tab:t2"), builder.actions)  # the chat is the tab that the pane shows at the keys
        self.assertLess(app.calls.index(("debug.agent_pane", "focus_composer")), app.calls.index(("debug.key", None)))

    def close_move(self, motion):
        letters, builder, app = self.letters(CHORD, {"t3": "x"}, motion=motion)
        return letters.case("close-move", 0), builder, app

    def test_a_close_that_moves_its_panes_keeps_the_apps_note_of_the_move(self):
        record, builder, app = self.close_move(MOVE)
        self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record["moved"], record["panes_after"]), (None, True, True, True, 1))
        # The record has the app's notes of the close, and no note of another part.
        self.assertEqual(record["motion"]["notes"], [{"t_ms": 3.0, "text": "layout.commit: close moves 1 panes for 0.25 s"}])
        self.assertEqual((record["motion"]["pane_animations"], record["motion"]["reduce_motion"]), (True, False))
        # The sequence goes to the second pane (the Close Tab key closes it), the new tabs come in the first pane,
        # and the trace runs from before the keys to after them.
        self.assertEqual((app.sequences[-1]["pane"], [step["key_code"] for step in app.sequences[-1]["sequence"] if step["down"]][:2]), ("q", [M.CMD, M.W]))
        self.assertEqual(builder.tabs_of, {"p": ["first", "t1", "t3", "t4"]})
        calls = [call for call in app.calls if call[0] in ("debug.motion", "debug.key")]
        self.assertEqual(calls[-3:], [("debug.motion", "start"), ("debug.key", None), ("debug.motion", "stop")])

    def test_a_close_in_one_frame_is_a_case_with_no_move_and_the_form_is_not_proved(self):
        # The case itself passes (no key dropped, the letter in the field): the form's word must not be PASS, for the
        # close did not move a pane. The same with Reduce Motion (the app then gives no note of a move), and with
        # no reply of the trace.
        still = {"pane_animations": True, "reduce_motion": True, "spans": [], "notes": []}
        for motion in (ONE_FRAME, still, None):
            letters, _, _ = self.letters(CHORD, {"t3": "x", "t7": "x"}, motion=motion)
            found = letters.run(2, forms=("close-move",), say=lambda line: None)["forms"][0]
            self.assertEqual((found["verdict"], found["chord_pass"]), ("NOT PROVED: too few cases in a close's move", 2), motion)
            self.assertEqual((found.get("move"), found.get("no_move")), (0, 2), motion)
            record, _, _ = self.close_move(motion)
            self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record.get("moved")), (None, True, True, False), motion)
            self.assertEqual(record["motion"]["notes"], (motion or {}).get("notes", []))

    def test_two_closes_that_move_make_the_form_pass(self):
        letters, _, _ = self.letters(CHORD, {"t3": "x", "t7": "x"}, motion=MOVE)
        found = letters.run(2, forms=("close-move",), say=lambda line: None)["forms"][0]
        self.assertEqual((found["verdict"], found.get("move"), found.get("no_move")), ("PASS", 2, 0))

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
        # Each line is JSON after its name, as each other line of the measure: a reader parses it with no eval.
        for line, name, record in zip(said, ("HELD-NEW-TAB-LETTER-CASE ", "HELD-NEW-TAB-LETTER-FORM "), (report["cases"][0], report["forms"][0])):
            self.assertTrue(line.startswith(name), line)
            self.assertEqual(json.loads(line[len(name):]), record)

    def test_the_words_for_a_run_in_which_no_case_ran(self):
        self.assertEqual(M.ran_none({"not_run": "the run ended before the letter cases"}), "the run ended before the letter cases")
        self.assertTrue(M.ran_none({"forms": []}))
        self.assertTrue(M.ran_none(None))
        late = [M.verdict(form, [{"form": form, "case": 0, "not_run": "why"}]) for form in ("three-key", "two-key")]
        self.assertEqual(M.ran_none({"forms": late}), "each form is NOT RUN")
        # One form with a case that ran: the run has a word of its own (PASS, FAIL or NOT PROVED), and that is a read.
        for case in (M.judge("three-key", CHORD, "x"), M.judge("three-key", DROP, ""), M.judge("three-key", READY, "x")):
            self.assertIsNone(M.ran_none({"forms": late + [M.verdict("three-key", [case])]}))

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
