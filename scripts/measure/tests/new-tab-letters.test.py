#!/usr/bin/env python3
"""scripts/measure/new-tab-letters.py: the 3 keys as steps, the cut of the hold's log, a case's verdict, a form's word.

What these rows hold: each key-down of the 3 keys is 30 ms after the key-down before it, and the letter goes down
with no Command; the notes of a case are the notes after the read before it, also when the log's ring lost its
oldest notes; a case is a `chord` case only when the hold ended at the second New Tab key with keys and no report
of the page before it, and a report of the setup before the case's first `begin` makes no `ready` case; the rule
(`dropped 0`, the field is the letter, and no text in the park at the tool's last call before its own acts on the
first new tab, in each form); a case with a text in the park at that read whose field then has the letter is `typed
only after the select` and no pass, a form's line counts the cases with such a text, and a case with no counts of
the park at a read before the tool's acts, or with a count below 0, is `not_run` with no select; a case with a text
in the park makes no act but a read of the park each 0.1 s, to the first read with no text or to 4 s after the
sequence's last key (also when the app types or drops the text later than 2 s of the tool's clock, in each of the 7
forms, and with a slow read before or in the wait), so a text that the app types by itself in the park's time can
pass, and the late word is said only for a text at the last read; a text at the last read before the bound gets a
second wait, with a second read of the journal and a new last read of the park; the record has the count at the
first read, the seconds to the read from which the park had no text
and to the last read, and a form's line the count of the cases that waited and their most seconds, with the cases
that are `not_run` in their wait; a case that stops by an exception, and a workspace that does not close, have the
exception's class name and no text of it; holds that are no list give no count; a case with a
text in the park before its keys is `not_run` and sends no key; the journal's read comes before the last read of
the park; a record has the journal's counts of the readiness notes, of the first new tab's focus and of the page
entries of each tab, the app's engine word of that tab, and the count of the open New Tab key holds, with no other
text of an entry and no id, and a journal with no read (at the first read or only at the second), with an odd last
number or with an entry whose number is no number changes no verdict; the journal's read after the select comes
directly after the read of the window and before the reads of the places (they select other tabs, and the app can
then give the first new tab's page view to another tab: an entry of that view after such a select is not in the
counts): the record has the first new tab's engine word and the counts of
the entries after the last read of the journal before the select (not of an entry before that read), the whole
record but these 2 keys, each other call and act and the form's line are those of a tool with no such
read (in each of the 7 forms), a failed read gives no engine word and the why and ends no case and no run, with
no read before the select the tool reads no entries after it (also when only the second of 2 reads before the
select failed), and a case that is `not_run` before the read after its select has no such key; the journal names a
cmux page in Chromium by the page's own random id: the tool takes that id from ONE read of the window's word
(`debug.focus`) directly after the verdict's read of the field, only when the window's focus model names the first
new tab, counts the entries before and after the select by it, and keeps no id in a record; with no id and no
entry of the tab's id the record has the word `not readable for a cmux page in Chromium` and no count of 0; the
record's `shown_page_has_chromium_focus` (yes, no, no read), and the class of the view with the keyboard before
the keys, after them and after the select, with no other text of the app; the id names a page view, which the app
can give from one tab to another: the record's `page_is_the_windows_page_before_the_keys` says if the id is the
one that the window had before the keys (yes, no, and None with no id or no read before the keys), from an id
that the tool keeps in memory for that one case; that read changes no other key of the
record and no form's line (in each of the 7 forms), and a failed one ends no case and no run; `chromium_given`
counts only a give with the word `chromium`; the journal's last number at a read is the larger of the reply's
number and the largest number of its entries, so an entry between the app's 2 reads is counted one time; where the
letter is (`letter_is`): ONE word of the 12, the
first that is true, from the 2 new tabs' fields, the fields of the tabs that the pane showed before and the park's
counts, and each other true word in `letter_also`; `nowhere read` only for a case that ran, with no dropped key
and an answer of each place: else `not run`, `dropped by the hold`, `a place not read`; a place that gave no
answer (no element, no text, an error, no dict, no counts of the park, an exception) is in `places_not_read`
with its name, and a form counts its cases with such a place; `tab before` needs a read before the keys; a record
has the app's word on its active state, the park's counts at 4 times, no text of a field but the letter and no
title; a place with no read changes no verdict and makes no case `not_run`; the reads of the places come after
the old reads; a form with too few chord cases is NOT PROVED; a case's steps against a model app, and a case whose setup
fails is `not_run` and closes its workspace; a close-move case keeps the app's notes of the close, a case whose close
did not move is counted apart, and the form with too few cases in a move is NOT PROVED; a case with no note of a
hold's start is `not_run`; a switch case whose setup letters did not get to their fields is `not_run`; each printed
line is JSON after its name; the words for a run in which no case ran; the tab that a pane shows is the pane's
`selected_tab` of the snapshot (no key of a tab), else the focus model's word; a select that the pane shows late is
waited for, and one that it never shows is `not_run` with the shown tab and the app's refusal, in a setup too.

No app: the app is a small model of the calls that a case makes. So this proves the tool's own logic, NOT that the
app drops or keeps a letter, NOT that a key of a sequence reaches a page, NOT that the app writes the notes of a
close in the words of the model (they are copied from the app's source), NOT that the app's snapshot has the
keys of the model (they are copied from the app's source too: ControlTopology+JSON.swift, DebugFocus.swift), NOT
that the app's journal has the entries of the model (their form is of InputJournalEntry.swift, the notes' words of
PageInputReadiness.swift, the engine words of FocusEffectApplier.swift), NOT that the id of a window's Chromium
page in `debug.focus` is the id that the journal's entries of that page have (by a read of the app's source they
are the same: FocusEffectApplier.swift `focusedChildWindowPageID`, `setPageFocus`; the model gives a page ONE
fixed id for both), NOT that the app's window has the class names of the model, NOT
that the app writes a page entry at the tool's select of a tab (the model writes what a row gives it), and
NOT that a chat's composer answers the tool's selector (the reply's form is of PageWebView+DebugProbe.swift).
Run: python3 -I scripts/measure/tests/new-tab-letters.test.py"""
import importlib.util, json, os, unittest
from unittest import mock

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
        self.assertEqual(M.judge(CHORD, "x"), {"chord": True, "dropped": 0, "letter_in_field": True, "pass": True})

    def test_a_dropped_letter_fails_in_each_form(self):
        # One rule for each form: to 22 November 2026 from-chat wanted this drop (`dropped 1`, an empty field).
        found = M.judge(DROP, "")
        self.assertEqual((found["chord"], found["dropped"], found["pass"]), (True, 1, False))
        self.assertFalse(M.judge(DROP, "x")["pass"])  # the letter in the field with a dropped key is no pass

    def test_a_ready_case_wants_the_letter(self):
        found = M.judge(READY, "x")
        self.assertEqual((found["chord"], found["pass"]), (False, True))
        self.assertFalse(M.judge(READY, "")["pass"])

    def test_a_chord_with_no_keys_is_no_chord_case(self):
        self.assertFalse(M.judge(["release: chord, no keys to page +60ms"], "x")["chord"])

    def test_a_report_of_the_setup_before_the_cases_first_begin_makes_no_ready_case(self):
        # By a run of close-move: a page of the setup reported after the tool's read of the log, so the case's notes
        # start with that report. The case's own hold ended at the second New Tab key: a `chord` case.
        found = M.judge(["ready match +440ms", "drained to field +440ms"] + CHORD, "x")
        self.assertEqual((found["chord"], found["pass"]), (True, True))
        # A report after the case's first `begin` and before the release is the case's own: a `ready` case.
        self.assertFalse(M.judge(["old +0ms"] + READY[:3] + CHORD[2:], "x")["chord"])

    def test_no_read_of_the_field_is_no_pass(self):
        found = M.judge(CHORD, None)
        self.assertEqual((found["letter_in_field"], found["pass"]), (None, False))

    def test_the_field_is_the_letter_and_no_more(self):
        # A letter that came 2 times, or with another character, is in the field and is no pass.
        for text in ("xx", "xt", " x"):
            found = M.judge(CHORD, text)
            self.assertEqual((found["letter_in_field"], found["pass"]), (True, False), text)


class Places(unittest.TestCase):
    def test_a_record_has_no_text_of_a_field_but_the_letter(self):
        self.assertEqual([M.seen(text) for text in (None, "", "x", "xx", "xt", "a title", 7)],
                         [None, "", "x", "the letter 2 times", "the letter and other text", "other text", None])

    def test_a_field_got_the_letter_when_it_has_one_more(self):
        self.assertEqual([M.gained(was, now) for was, now in (("", "x"), ("x", "xx"), ("x", "x"), ("", ""), ("", None), (None, "x"), ("x", "t"))],
                         [True, True, False, False, None, None, False])  # with no read before or after: not known, not yes

    def test_the_parks_counts_of_a_case(self):
        zero = dict.fromkeys(M.PARK, 0)
        self.assertEqual(M.park_of({"parked_typing": {"parked": 3.0, "typed": 2.0}}), {**zero, "parked": 3, "typed": 2})
        self.assertIsNone(M.park_of({"new_tab_key_log": []}))  # an app with no counts: no read, not zero
        self.assertIsNone(M.park_of({"parked_typing": {"parked": "many"}}))  # a count that is no number: no read, no exception
        self.assertEqual(M.park_change({**zero, "parked": 3}, {**zero, "parked": 4, "dropped_old": 1}), {**zero, "parked": 1, "dropped_old": 1})
        self.assertIsNone(M.park_change(None, zero))

    def test_where_the_letter_is_is_each_word_that_is_true_in_the_order_of_the_list(self):
        change = lambda **counts: {**dict.fromkeys(M.PARK, 0), **counts}
        every = change(parked=5, dropped_refused=1, dropped_old=1, dropped_page_gone=1)
        found = [M.where("x", "x", True, every)[0], M.where("", "x", True, every)[0], M.where("", "", True, every)[0], M.where("", None, False, every)[0],
                 M.where("", "", False, change(parked=1, dropped_old=1, dropped_page_gone=1))[0], M.where(None, None, False, change(parked=1, dropped_page_gone=1))[0],
                 M.where("", "", False, change(parked=1))[0]]
        self.assertEqual(found, list(M.WHERE[1:8]))
        # 2 places and more with the letter: each true word, in the list's order (the first is `letter_is`).
        self.assertEqual(M.where("x", "x", True, every, 1, True), list(M.WHERE[1:8]))
        self.assertEqual(M.where("", "x", False, change(dropped_old=1)), ["second new tab's field", "dropped after the bound"])
        self.assertEqual((len(M.WHERE), len(set(M.WHERE))), (12, 12))

    def test_the_first_word_of_a_letter_that_came_to_its_field_after_a_text_waited_before_the_select(self):
        typed = {**dict.fromkeys(M.PARK, 0), "parked": 1, "typed": 1}
        self.assertEqual(M.WHERE[:2], ("typed only after the select", "new tab's field"))
        self.assertEqual(M.where("x", "", False, typed, waited=1), ["typed only after the select", "new tab's field"])
        self.assertEqual(M.where("x", "", False, typed, waited=0), ["new tab's field"])
        # A text that waited and came to no field of the first new tab has the word of its place, as before.
        self.assertEqual(M.where("", "x", False, typed, waited=1), ["second new tab's field"])
        self.assertEqual(M.where("", "", False, {**typed, "typed": 0, "dropped_old": 1}, waited=1), ["dropped after the bound"])

    def test_the_texts_in_the_park_at_a_read_are_each_that_came_less_each_that_left(self):
        counts = lambda **some: {**dict.fromkeys(M.PARK, 0), **some}
        self.assertEqual([M.waiting(counts(parked=5)), M.waiting(counts(parked=5, typed=2, dropped_old=1, dropped_refused=1, dropped_page_gone=1)),
                          M.waiting(counts(parked=2, typed=2, dropped_returns=3)), M.waiting(None)], [5, 0, 0, None])

    def test_nowhere_read_is_said_only_when_the_hold_dropped_0_and_each_place_answered(self):
        typed = {**dict.fromkeys(M.PARK, 0), "parked": 1, "typed": 1}  # a typed text that no read finds
        self.assertEqual([M.where("", "", False, typed, dropped, unread) for dropped, unread in ((0, False), (0, True), (1, False), (1, True))],
                         [["nowhere read"], ["a place not read"], ["dropped by the hold"], ["dropped by the hold"]])
        self.assertEqual(M.where("t", None, False, None, 0, True), ["a place not read"])
        self.assertEqual(M.WHERE[8:], ("not run", "dropped by the hold", "a place not read", "nowhere read"))
        self.assertEqual(M.where("x", None, False, None, 1, True), ["new tab's field"])  # a place with the letter is said first


class Verdict(unittest.TestCase):
    def cases(self, chords, readies, form="three-key"):
        return [M.judge(CHORD, "x") for _ in range(chords)] + [M.judge(READY, "x") for _ in range(readies)]

    def closes(self, moves, plain):
        """Cases of close-move that each pass with a chord: `moves` in a move of the close, `plain` with no move."""
        return [{**M.judge(CHORD, "x"), "moved": index < moves} for index in range(moves + plain)]

    def test_a_close_with_no_move_is_counted_apart_and_too_few_moves_is_not_proved(self):
        found = M.verdict("close-move", self.closes(0, 12))  # each close in one frame: the form is the plain close of a pane
        self.assertEqual((found["verdict"], found["chord_pass"]), ("NOT PROVED: too few cases in a close's move", 12))
        self.assertEqual((found.get("move"), found.get("no_move")), (0, 12))
        self.assertEqual(M.verdict("close-move", self.closes(5, 7))["verdict"], M.NO_MOVE)
        found = M.verdict("close-move", self.closes(6, 6))
        self.assertEqual((found["verdict"], found.get("move"), found.get("no_move")), ("PASS", 6, 6))
        self.assertTrue(M.NO_MOVE.startswith("NOT PROVED") and M.NO_MOVE != M.NOT_PROVED)

    def test_a_failed_close_case_fails_with_no_move_too_and_no_other_form_counts_moves(self):
        self.assertEqual(M.verdict("close-move", self.closes(0, 11) + [{**M.judge(DROP, ""), "moved": False}])["verdict"], "FAIL")
        self.assertNotIn("move", M.verdict("three-key", self.cases(6, 6)))

    def test_a_form_with_enough_chord_cases_passes(self):
        found = M.verdict("three-key", self.cases(6, 6))
        self.assertEqual((found["verdict"], found["chord"], found["chord_pass"], found["ready"], found["ready_pass"]), ("PASS", 6, 6, 6, 6))

    def test_too_few_chord_cases(self):
        self.assertEqual(M.verdict("three-key", self.cases(5, 7))["verdict"], M.NOT_PROVED)

    def test_the_guard_form_needs_no_chord_case(self):
        self.assertEqual(M.verdict("two-key", self.cases(0, 12, "two-key"))["verdict"], "PASS")

    def test_a_forms_counts_say_where_its_letters_are_in_the_order_of_the_list(self):
        unread = {**M.judge(CHORD, ""), "letter_is": "a place not read", "places_not_read": ["field: no text"]}
        cases = [{**M.judge(CHORD, ""), "letter_is": "parked"}, {"not_run": "why"}, unread] + [{**M.judge(CHORD, "x"), "letter_is": "new tab's field"}] * 2
        found = M.verdict("three-key", cases)
        self.assertEqual(list(found["letter_is"].items()), [("new tab's field", 2), ("parked", 1), ("not run", 1), ("a place not read", 1)])
        self.assertEqual(found["places_not_read"], 1)  # the count of the cases with a place that gave no read
        self.assertEqual(M.verdict("three-key", cases[:2])["places_not_read"], 0)

    def test_one_failed_case_or_one_case_not_run_fails(self):
        self.assertEqual(M.verdict("three-key", self.cases(11, 0) + [M.judge(DROP, "")])["verdict"], "FAIL")
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
    what the app says to a select that it does not do (`only`: of these tabs; None: of each tab). `store`: False
    when the snapshot names no shown tab. `chats`: the tabs that are agent chats."""

    def __init__(self, late=0, refuse=None, store=True, only=None):
        self.tabs_of, self.shown, self.focused = {"p": ["first"]}, {"p": "first"}, "p"
        self.actions, self.chat_fallbacks, self.count, self.chats = [], 0, 0, set()
        self.late, self.refuse, self.store, self.coming, self.only = late, refuse, store, None, only

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
        self.chats |= {self.shown[pane]} if kind == "chat" else set()

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
            if self.refuse and (self.only is None or tab in self.only):
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
    does not get to its field. `focus`: `debug.focus` has the focus model's word on each pane (DebugFocus.swift).
    At the keys of a case (a sequence with a New Tab key and the letter): `lands` are texts that fields then get,
    and `park` goes on the park's counts (`parked_typing`); `park_end` goes on them at the first read of
    `debug.focus` after a read of a field that came after those keys (a field is read only after the select of the
    first new tab, so each read before that select has the counts with no `park_end`). `active`: the app's word
    `app_active`. The field of a
    chat is its composer: `field` has no text for it (and has titles in `open_tabs`), `query` has its text.
    `had`: the park's counts before the first key. `counts` False: `debug.focus` has no `parked_typing`. `query`:
    the replies of the first queries of a chat's composer, in their order (then the model's own reply). `journal`:
    the kinds of the entries that the app's input journal gets at the keys of a case (`debug.journal`, in the form
    of InputJournalEntry.swift); None: an app with no reply to `debug.journal`. The reads of `debug.focus` after
    the keys of a case have numbers: 1 is the read of the hold's log, 2 the first read of the park before the tool's
    acts. `turns`: the counts that go on the park's counts at the read of a number; `blind`: the numbers of the
    reads with no `parked_typing`; `fails`: the numbers of the reads that raise. `holds`: the windows with an open
    New Tab key hold (`new_tab_key_holds`; None: the reply has no such key; a value that is no list is the reply's
    value as it is). `slow`: the seconds that the read of a number takes on the model's clock (`clock`). `after`:
    the kinds of the entries that the journal gets at the first read of a field after the keys of a case (a field
    is read only after the select of the first new tab: the entries of the select). `pages`: the id of the
    Chromium page of each tab whose page is in Chromium (a tab that is not in it has its page in a WebKit view);
    with it `debug.focus` has, for its window, the class of the first responder (the window's class with a
    Chromium page's focus, as in the app: FocusEffectApplier.swift `focusPage`), the id of the Chromium page
    that has the page focus (the page of the tab that the pane with the keyboard shows, or null), and the focus
    model's tab (that shown tab), in the keys of DebugFocus.swift `appkit` and `model`. None: a reply with no
    such keys. `lost`: the tabs whose Chromium page the app gave no page focus (the window names no page for
    them). `views`: the first responder's word for a shown tab, as it is (None: the JSON null of a window with
    none). `aims`: the focus model's tab for a shown tab, when it is not that tab (None: the JSON null). `dead`:
    the numbers of the reads of `debug.focus` after a case's first read of a field that raise (1: the tool's read
    after its select). `moved`: the kinds of the entries that the journal gets at the first call after the pane
    with the keyboard shows another tab than at that first read of a field (a tool's select of another tab for
    the reads of the places: the app gives the first new tab's page view to that tab, and that view the focus)."""

    def __init__(self, builder, notes, texts, refuse=None, motion=None, deaf=False, focus=False, lands=None, park=None, park_end=None, active=True,
                 had=None, counts=True, query=(), journal=(), turns=None, blind=(), fails=(), holds=None, slow=None, after=(), pages=None, lost=(), dead=(),
                 views=None, aims=None, moved=()):
        self.slow, self.after, self.wrote, self.pages, self.lost, self.dead, self.later = slow or {}, after, True, pages, lost, dead, None
        self.views, self.aims, self.moved, self.first_shown = views or {}, aims or {}, moved, None
        self.builder, self.notes, self.texts, self.refuse, self.log, self.sequences = builder, notes, texts, refuse, ["old +0ms"], []
        self.motion, self.deaf, self.calls, self.focus, self.active = motion, deaf, [], focus, active
        self.lands, self.park, self.park_end, self.counts = lands or {}, park or {}, park_end or {}, {**dict.fromkeys(M.PARK, 0), **(had or {})}
        self.has_counts, self.query, self.keyed, self.fielded = counts, list(query), False, False
        self.turns, self.blind, self.fails, self.holds, self.reads = turns or {}, blind, fails, holds, None
        self.journal, self.entries, self.seq = journal, [{"seq": 40, "kind": {"content": {"tab": "readiness", "event": "page epoch=1"}}}], 40

    def count(self, more):
        self.counts = {key: count + more.get(key, 0) for key, count in self.counts.items()}

    def write(self, kinds):
        for kind in kinds or ():
            self.seq += 1
            self.entries.append({"seq": self.seq, "uptimeNanos": 7, "window": None, "kind": kind})

    def __call__(self, method, params=None):
        params = params or {}
        self.calls.append((method, params.get("action")))
        if self.first_shown not in (None, self.builder.selected):  # the pane shows another tab than at the verdict's read
            self.write(self.moved)
            self.first_shown = None
        if method == "debug.key":
            if self.refuse:
                return {"error": self.refuse}
            self.sequences.append(params)
            keys = [step["key_code"] for step in params["sequence"] if step["down"]]
            if keys == [M.X] and not self.deaf:
                self.texts[self.builder.selected] = "x"  # a letter alone goes to the field of the shown tab
            if M.T in keys and M.X in keys:
                self.texts.update(self.lands)
                self.count(self.park)
                self.keyed, self.reads, self.wrote = True, 0, False
                self.write(self.journal)
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
            self.count(self.park_end if self.fielded else {})
            self.keyed, self.fielded = self.keyed and not self.fielded, False
            self.reads = None if self.reads is None else self.reads + 1
            self.count(self.turns.get(self.reads, {}))
            if self.reads in self.slow:
                self.clock.take(self.slow[self.reads])
            if self.reads in self.fails:
                raise KeyError("a text of the app")
            self.later = None if self.later is None else self.later + 1
            if self.later in self.dead:
                raise KeyError("a text of the app")
            shown = self.builder.selected
            has = self.pages.get(shown) if self.pages is not None and shown not in self.lost else None
            words = {} if self.pages is None else {"appkit": {"first_responder": self.views.get(shown, "ShellWindow" if has else "PageWKWebView"),
                                                              "classified": "content", "child_window_page": has, "devtools_tab": None},
                                                   "model": {"resolved_pane": self.builder.focused, "resolved_tab": self.aims.get(shown, shown)}}
            return {"new_tab_key_log": list(self.log), "app_active": self.active, "key_window": "PageWindow",
                    **({"parked_typing": {key: float(count) for key, count in self.counts.items()}} if self.has_counts and self.reads not in self.blind else {}),
                    **({} if self.holds is None else {"new_tab_key_holds": list(self.holds) if isinstance(self.holds, list) else self.holds}),
                    **({"windows": [{"topology": panes, **words}]} if self.focus or self.pages is not None else {})}
        if method == "debug.journal" and self.journal is not None:
            return {"stats": {"enabled": True, "lastSeq": self.seq}, "entries": self.entries[-params.get("last", 200):]}
        chat = self.builder.selected in self.builder.chats
        if method == "debug.new_tab" and params.get("action") == "field":
            self.fielded = self.keyed
            if not self.wrote:
                self.write(self.after)
                self.wrote, self.later, self.first_shown = True, 0, self.builder.selected
            return {"text": None if chat else self.texts.get(self.builder.selected, ""), "focused": True, "open_tabs": ["a title"]}
        if method == "debug.agent_pane" and params.get("action") == "query" and chat and self.query:
            return self.query.pop(0)
        if method == "debug.agent_pane" and params.get("action") == "query":
            return {"pane": params.get("pane"), "elements": [{"classes": [], "text": self.texts.get(self.builder.selected, "")}] if chat else []}
        if method == "debug.new_tab":  # an opening of an app with no key `idle` (DebugNewTab.swift has that key now)
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


class Clock:
    """The model's time, in ms: a pause of the tool takes time, and a call of the app takes none but a read that the
    model names as slow (`take`)."""

    def __init__(self):
        self.ms, self.pauses = 0, []

    def pause(self, seconds):
        self.pauses.append(seconds)
        self.ms += round(seconds * 1000)

    def take(self, seconds):
        self.ms += round(seconds * 1000)

    def now(self):
        return self.ms / 1000


class Case(unittest.TestCase):
    def letters(self, notes, texts, refuse=None, builder=None, wait=wait, **model):
        builder = builder or Builder()
        app = App(builder, notes, texts, refuse, **model)
        app.clock = Clock()
        return M.Letters(builder, app, wait, pause=app.clock.pause, clock=app.clock.now), builder, app

    def test_the_shown_tab_is_the_panes_selected_tab_and_no_key_of_a_tab(self):
        # The app's snapshot: a pane has `selected_tab`, and a tab of the daemon has no key `selected`. A tool that
        # wants `selected` in a tab finds no shown tab in any pane: then each case of each form is `not_run`.
        letters, builder, _ = self.letters(CHORD, {"t2": "x"})
        self.assertEqual([sorted(pane) for pane in builder.panes({"id": "w"})], [["id", "selected_tab", "tabs"]])
        self.assertNotIn("selected", builder.tabs("w", "p")[0])
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record.get("pass"), record.get("field")), (None, True, "x"))
        self.assertEqual(letters.shown("w", "p"), "t1")  # the case's last select: the tab that the pane showed before

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

    def test_the_form_from_a_chat_opens_a_chat_gives_its_field_the_keyboard_and_wants_the_letter_in_the_new_tab(self):
        letters, builder, app = self.letters(CHORD, {"t3": "x"})
        record = letters.case("from-chat", 0)
        self.assertEqual((record.get("not_run"), record["pass"], record["chord"], record["dropped"], record["field"]), (None, True, True, 0, "x"))
        self.assertEqual((record["letter_is"], record["tabs_before"]), ("new tab's field", [{"field_before": "", "field": "", "got_the_letter": False}] * 2))
        self.assertIn(("add_tab chat", "pane:p"), builder.actions)
        self.assertIn(("tab.focus", "tab:t2"), builder.actions)  # the chat is the tab that the pane shows at the keys
        self.assertLess(app.calls.index(("debug.agent_pane", "focus_composer")), app.calls.index(("debug.key", None)))
        # The case of the rule to 22 November 2026 (the hold drops the letter, an empty field) is no pass.
        record = self.letters(DROP, {})[0].case("from-chat", 0)
        self.assertEqual((record["pass"], record["dropped"], record["field"], record["letter_is"]), (False, 1, "", "dropped by the hold"))

    def test_a_letter_in_the_chats_composer_is_tab_before_and_the_record_has_no_text_and_no_title(self):
        letters, builder, app = self.letters(CHORD, {"t2": "a draft"}, lands={"t2": "a draftx"})
        record = letters.case("from-chat", 0)
        self.assertEqual((record["pass"], record["field"], record["letter_is"]), (False, "", "tab before"))
        self.assertEqual(record["tabs_before"][0], {"field_before": "other text", "field": "the letter and other text", "got_the_letter": True})
        self.assertIn(("debug.agent_pane", "query"), app.calls)
        self.assertEqual([word for word in ("draft", "a title") if word in json.dumps(record)], [])

    def test_a_record_has_the_parks_counts_at_4_times_and_the_apps_word_on_its_active_state(self):
        record = self.letters(CHORD, {}, park={"parked": 1}, park_end={"dropped_old": 1}, active=False)[0].case("three-key", 0)
        park = record["park"]
        self.assertEqual([(park[at]["parked"], park[at]["dropped_old"]) for at in ("before", "after", "select", "end", "change")],
                         [(0, 0), (1, 0), (1, 0), (1, 1), (1, 1)])
        self.assertEqual((record["pass"], record["letter_is"]), (False, "dropped after the bound"))
        self.assertEqual(record["app"], {"active_before": False, "active_after": False, "active_end": False,
                                         "key_window_before": "PageWindow", "key_window_after": "PageWindow"})
        # Each other word of a letter that is not in the first new tab's field, from the model's counts and fields.
        for model, word in (({"park": {"parked": 1, "dropped_refused": 1}}, "refused by the field"), ({"park": {"parked": 1, "dropped_page_gone": 1}}, "page gone"),
                            ({"park": {"parked": 1}}, "parked"), ({"park": {"parked": 1, "typed": 1}}, "nowhere read"),
                            ({"lands": {"t3": "x"}}, "second new tab's field"), ({"lands": {"t1": "x"}}, "tab before")):
            record = self.letters(CHORD, {}, **model)[0].case("three-key", 0)
            self.assertEqual((record["pass"], record["letter_is"], record["app"]["active_end"]), (False, word, True), model)

    def test_the_reads_of_the_places_come_after_the_old_reads_and_a_failed_one_changes_no_verdict(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"})
        record = letters.case("three-key", 0)
        # The select of the first new tab and its field are first, as before; then the second new tab, then the tab before.
        self.assertEqual([target for name, target in builder.actions if name == "tab.focus"], ["tab:t2", "tab:t3", "tab:t1"])
        self.assertEqual((record["second_new_tab_field"], record["tabs_before"], record.get("places_not_read")),
                         ("", [{"field_before": "", "field": "", "got_the_letter": False}], None))
        # The journal's read after the select comes directly after the read of the window and before the reads of the
        # places (the fields of the 2 other tabs); the park's counts of the end are the last read, the case's last call.
        last = len(app.calls) - 1 - app.calls[::-1].index(("debug.journal", None))
        self.assertEqual((app.calls[last - 1], app.calls[last + 1:]), (("debug.focus", None), [("debug.new_tab", "field")] * 2 + [("debug.focus", None)]))
        # The app refuses the selects of the second new tab and of the tab before: the verdict stays, the record says why.
        record = self.letters(CHORD, {"t2": "x"}, builder=Builder(refuse="no", only=("t1", "t3")))[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["second_new_tab_field"], record["tabs_before"][0]["field"]), (True, "new tab's field", None, None))
        self.assertEqual(record["places_not_read"],
                         [f"{place}: the pane shows the tab t2, not the tab {tab}, after its select: the app said: no"
                          for place, tab in (("second_new_tab_field", "t3"), ("tabs_before[0]", "t1"))])

    def test_a_chat_whose_query_has_no_element_is_a_place_not_read_and_not_nowhere_read(self):
        # The letter can be in the chat's composer: with no answer of the query the tool does not know it, and says so.
        record = self.letters(CHORD, {}, query=[{"elements": []}] * 2)[0].case("from-chat", 0)
        self.assertEqual((record["pass"], record["field"], record["letter_is"]), (False, "", "a place not read"))
        self.assertEqual(record["places_not_read"], ["tabs_before[0] before the keys: no element", "tabs_before[0]: no element"])
        self.assertEqual(record["tabs_before"][0], {"field_before": None, "field": None, "got_the_letter": None})
        self.assertEqual(M.verdict("from-chat", [record])["places_not_read"], 1)
        # Each other reply with no text has its word.
        for reply, why in (({"error": "query failed"}, "error"), ("no", "no dict"), ({"elements": [{"classes": []}]}, "no text")):
            record = self.letters(CHORD, {}, query=[reply] * 2)[0].case("from-chat", 0)
            self.assertEqual((record["letter_is"], record["places_not_read"][-1]), ("a place not read", f"tabs_before[0]: {why}"), reply)

    def test_an_app_with_no_counts_of_the_park_before_the_select_is_not_run(self):
        # No read is not `no text waits`: with the letter in the first new tab's field too, the case proves nothing
        # (the tool's own select can be what typed it), and the tool makes no select.
        for texts in ({}, {"t2": "x"}):
            letters, builder, _ = self.letters(CHORD, texts, counts=False)
            record = letters.case("three-key", 0)
            self.assertEqual(record.get("not_run"), "the read before the select has no counts of the park: no read of a text that waits there", texts)
            self.assertEqual(("pass" in record, record["letter_is"], record["park"]), (False, "not run", {"before": None, "after": None, "select": None}))
            self.assertEqual([action for action in builder.actions if action[0] == "tab.focus"], [])
            self.assertEqual(M.verdict("three-key", [record])["verdict"], "NOT RUN")

    def test_no_text_of_the_first_new_tabs_field_is_a_place_not_read(self):
        record = self.letters(CHORD, {"t2": None})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["field"], record["letter_is"], record["places_not_read"]), (False, None, "a place not read", ["field: no text"]))

    def test_tab_before_is_not_said_with_no_read_before_the_keys(self):
        # The composer has the letter after the keys, and its read before the keys gave no element: the letter can be older.
        record = self.letters(CHORD, {}, lands={"t2": "x"}, query=[{"elements": []}])[0].case("from-chat", 0)
        self.assertEqual((record["letter_is"], record["tabs_before"][0]), ("a place not read", {"field_before": None, "field": "x", "got_the_letter": None}))
        self.assertEqual(record["places_not_read"], ["tabs_before[0] before the keys: no element"])

    def test_a_letter_in_2_places_has_the_other_words_in_letter_also(self):
        record = self.letters(CHORD, {"t2": "x"}, lands={"t3": "x", "t1": "x"}, park={"parked": 1, "dropped_old": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"]), (True, "new tab's field"))
        self.assertEqual(record["letter_also"], ["second new tab's field", "tab before", "dropped after the bound"])
        self.assertNotIn("letter_also", self.letters(CHORD, {"t2": "x"})[0].case("three-key", 0))  # one place: no such key

    def test_an_exception_of_the_place_reads_makes_no_case_not_run(self):
        # The case has its verdict by the 2 old reads: the record has the exception's class name only, and no `not_run`.
        for texts, passed, word in (({"t2": "x"}, True, "new tab's field"), ({}, False, "a place not read")):
            with mock.patch.object(M, "park_change", side_effect=KeyError("a text of the app")):
                record = self.letters(CHORD, texts)[0].case("three-key", 0)
            self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"]), (passed, None, word))
            self.assertEqual(record["places_not_read"], ["the places: KeyError"])
            self.assertEqual(M.verdict("three-key", [record])["ran"], 1)

    def test_an_exception_of_one_place_read_is_its_class_name_and_the_next_read_goes_on(self):
        letters, record = self.letters(CHORD, {})[0], {}
        self.assertIsNone(letters.tried(record, "tabs_before[0]", lambda: {}["a text of the app"]))
        self.assertEqual(letters.tried(record, "tabs_before[1]", lambda: ("x", None)), "x")
        self.assertEqual(record, {"places_not_read": ["tabs_before[0]: KeyError"]})

    def test_a_two_key_case_has_no_second_new_tab_and_that_is_no_place_not_read(self):
        letters, builder, _ = self.letters(READY[:3], {})
        record = letters.case("two-key", 0)
        self.assertEqual((record["tabs_made"], record["second_new_tab_field"], record["letter_is"], record.get("places_not_read")), (1, None, "nowhere read", None))
        self.assertEqual([target for name, target in builder.actions if name == "tab.focus"], ["tab:t2", "tab:t1"])

    def test_a_switch_case_whose_letter_went_to_a_tab_before_has_the_letter_2_times_there(self):
        record = self.letters(CHORD, {}, lands={"t1": "xx"})[0].case("switch-next", 0)
        self.assertEqual((record["pass"], record["field"], record["letter_is"]), (False, "", "tab before"))
        self.assertEqual(record["tabs_before"], [{"field_before": "x", "field": "the letter 2 times", "got_the_letter": True},
                                                 {"field_before": "x", "field": "x", "got_the_letter": False}])

    def test_the_parks_counts_of_a_case_are_less_the_counts_before_its_keys(self):
        record = self.letters(CHORD, {}, had={"parked": 7, "typed": 4, "dropped_old": 3}, park={"parked": 1, "typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["park"]["before"]["dropped_old"], record["park"]["change"]), (3, {**dict.fromkeys(M.PARK, 0), "parked": 1, "typed": 1}))
        self.assertEqual(record["letter_is"], "nowhere read")  # an older count of a dropped text is not this case's

    def test_a_focus_reply_that_is_no_dict_is_a_read_with_no_counts(self):
        letters = M.Letters(Builder(), lambda method, params=None: ["no dict"], wait)
        self.assertEqual((letters.focus(), M.park_of(letters.focus())), ({}, None))

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
        self.assertEqual(("pass" in record, record["letter_is"]), (False, "not run"))
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_a_workspace_that_does_not_close_has_the_class_name_of_the_exception_and_no_text_of_it(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"})
        act = builder.action

        def action(name, *args, **more):
            if name == "closeWorkspace":
                raise RuntimeError("a text of the app")
            return act(name, *args, **more)
        builder.action = action
        record = letters.case("three-key", 0)
        self.assertEqual((record["workspace_not_closed"], record["pass"]), ("RuntimeError", True))
        self.assertNotIn("a text", json.dumps(record))

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
        for case in (M.judge(CHORD, "x"), M.judge(DROP, ""), M.judge(READY, "x")):
            self.assertIsNone(M.ran_none({"forms": late + [M.verdict("three-key", [case])]}))

    def test_a_case_after_the_budget_is_not_run(self):
        letters, builder, _ = self.letters(CHORD, {"t2": "x"})
        clock = iter([0.0, 1.0, 11.0, 12.0])
        report = letters.run(3, forms=("three-key",), say=lambda line: None, budget_s=10.0, now=lambda: next(clock))
        self.assertEqual([("not_run" in case) for case in report["cases"]], [False, True, True])
        self.assertIn("budget", report["cases"][1]["not_run"])
        self.assertEqual((report["forms"][0]["verdict"], report["forms"][0]["ran"], report["forms"][0]["not_run"]), (M.NOT_PROVED, 1, 2))
        self.assertEqual(report["forms"][0]["letter_is"], {"new tab's field": 1, "not run": 2})  # a case that did not run has its own word
        self.assertEqual(len([action for action in builder.actions if action[0] == "closeWorkspace"]), 1)


def page(tab, focused, engine="webkit"):
    """A journal entry's kind for a page that the app gave or took the focus (FocusEffectApplier.swift)."""
    return {"page": {"tab": tab, "focused": focused, "engine": engine}}


def note(event, tab="readiness"):
    """A journal entry's kind for a note of a page's input readiness (PageInputReadiness.swift `trace`)."""
    return {"content": {"tab": tab, "event": event}}


# The id of the own Chromium tab of the page of each tab of the model, in the form of the app's random ids. FIXED
# texts: a row gives the same result at each run. An id has no part of an id of the model's tabs (`t1`, `t2`, ...):
# no match by the tab's id finds it. PAGE: of the first new tab of a three-key case; OTHER_PAGE: of its second.
EACH = {f"t{number}": f"7C0B3E1{number}-52D4-4F6E-9A18-D3B5C2E4F601" for number in range(1, 9)}
PAGE, OTHER_PAGE = EACH["t2"], EACH["t3"]


class BeforeSelect(unittest.TestCase):
    """The tool's own select of the first new tab gives that tab the keyboard, and a parked text is typed then. So a
    case reads the park and the app's journal directly before its select, and a text that waits there is no pass."""

    letters = Case.letters

    def test_a_text_that_waits_before_the_select_and_is_typed_after_it_is_no_pass(self):
        # By a run of the 7 forms: in from-chat and three-key the parked text waited at the read after the keys in
        # each case, and the field had the letter after the tool's select in most of them: the old rule said PASS.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, park_end={"typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record.get("letter_also"), record.get("waits_before_select")),
                         (False, "typed only after the select", ["new tab's field"], 1))
        self.assertEqual((record["field"], record["dropped"], record["chord"], record.get("not_run")), ("x", 0, True, None))
        self.assertEqual([record["park"][at]["typed"] for at in ("before", "after", "select", "end")], [0, 0, 0, 1])

    def test_a_text_that_left_the_park_before_the_select_passes(self):
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1, "typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record.get("letter_also"), record["waits_before_select"]), (True, "new tab's field", None, 0))
        # No text came into the park (the page took the letter with no park): the same.
        record = self.letters(CHORD, {"t2": "x"})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (True, "new tab's field", 0))

    def test_a_text_that_waits_and_comes_to_no_field_keeps_the_word_of_its_end(self):
        record = self.letters(CHORD, {}, park={"parked": 1}, park_end={"dropped_old": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "dropped after the bound", 1))

    def test_a_text_in_the_park_before_the_keys_is_not_run_and_the_case_sends_no_key(self):
        # The park's counts do not say which text waits: a text that waits later can be the older one, and the word
        # `typed only after the select` would then be false for each later case of the run.
        for form, first in (("three-key", "t2"), ("close-move", "t3")):
            letters, builder, app = self.letters(CHORD, {first: "x"}, had={"parked": 3, "typed": 2}, park={"parked": 1, "typed": 1}, motion=MOVE)
            record = letters.case(form, 0)
            self.assertEqual(record.get("not_run"), "1 texts were in the park before the case's keys: a text that waits later can be an older one", form)
            self.assertEqual((record["waits_before_keys"], "pass" in record, record["letter_is"], sorted(record["park"])), (1, False, "not run", ["before"]), form)
            self.assertEqual((app.sequences, ("debug.motion", "start") in app.calls), ([], False), form)
            self.assertEqual(M.verdict(form, [record])["verdict"], "NOT RUN")
        # An empty park before the keys: the count is in the record, and the case runs.
        record = self.letters(CHORD, {"t2": "x"}, had={"parked": 3, "typed": 2, "dropped_old": 1})[0].case("three-key", 0)
        self.assertEqual((record["waits_before_keys"], record["pass"]), (0, True))

    def test_a_count_below_0_is_not_run_before_the_keys_and_before_the_select(self):
        # More texts left the park than came: the counts are no read of a text that waits (`not waits` is False for -1).
        letters, builder, app = self.letters(CHORD, {"t2": "x"}, had={"typed": 1})
        record = letters.case("three-key", 0)
        self.assertEqual((record.get("not_run"), record["waits_before_keys"], app.sequences),
                         ("the park's counts give -1 texts, a count below 0: no read of a text that waits there", -1, []))
        for model, reads in (({"park": {"typed": 1}}, 1), ({"turns": {3: {"typed": 1}}}, 2), ({"park": {"parked": 1}, "turns": {4: {"typed": 2}}}, 3)):
            letters, builder, app = self.letters(CHORD, {"t2": "x"}, **model)
            record = letters.case("three-key", 0)
            self.assertEqual(record.get("not_run"), "the park's counts give -1 texts, a count below 0: no read of a text that waits there", model)
            self.assertEqual(("pass" in record, record["waits_before_keys"], record.get("park_wait", {}).get("reads", 0)), (False, 0, reads - 1), model)
            self.assertEqual([action for action in builder.actions if action[0] == "tab.focus"], [], model)
            self.assertNotIn("waits_before_select", record)

    def test_the_rule_wants_no_text_in_the_park_before_the_select(self):
        self.assertEqual([M.judge(CHORD, "x", waits)["pass"] for waits in (0, 1, 2)], [True, False, False])
        self.assertFalse(M.judge(CHORD, "", 0)["pass"])

    def test_a_forms_line_counts_its_cases_with_a_text_that_waited_before_the_select(self):
        late = {**M.judge(CHORD, "x", 1), "letter_is": "typed only after the select", "waits_before_select": 1}
        lost = {**M.judge(CHORD, "", 1), "letter_is": "dropped after the bound", "waits_before_select": 1}
        good = {**M.judge(CHORD, "x", 0), "letter_is": "new tab's field", "waits_before_select": 0}
        found = M.verdict("three-key", [late] * 5 + [lost] + [good] * 6)
        self.assertEqual((found["verdict"], found["chord"], found["chord_pass"], found["waited_before_select"]), ("FAIL", 12, 6, 6))
        self.assertEqual(list(found["letter_is"].items()), [("typed only after the select", 5), ("new tab's field", 6), ("dropped after the bound", 1)])
        self.assertEqual(M.verdict("three-key", [good] * 12)["waited_before_select"], 0)

    def test_a_forms_line_counts_its_cases_that_waited_at_the_first_read_and_has_their_most_seconds_to_an_empty_park(self):
        case = lambda first, empty, waits: {**M.judge(CHORD, "x", waits), "waits_before_select": waits,
                                            "park_wait": {"first": first, "first_s": 0.77, "reads": 2, "empty_s": empty, "last_s": 4.07}}
        found = M.verdict("three-key", [case(1, 0.97, 0), case(2, 1.47, 0), case(1, None, 1), case(0, 0.77, 0), case(0, 1.9, 0), {"not_run": "why"}])
        self.assertEqual((found["waited_first_read"], found["emptied_latest_s"], found["waited_before_select"]), (3, 1.47, 1))
        # No case that waited, and cases that waited with no empty read: no seconds, and that is not 0.
        found = M.verdict("three-key", [case(0, 0.77, 0), {"not_run": "why"}])
        self.assertEqual((found["waited_first_read"], found["emptied_latest_s"]), (0, None))
        self.assertEqual(M.verdict("three-key", [case(1, None, 1)] * 2)["emptied_latest_s"], None)

    def ordered(self, **model):
        """A case of three-key: (its record, each call of the app, act of the tool and pause after the case's keys,
        to the select of the first new tab; the 2 calls before the keys)."""
        builder, order, clock = Builder(), [], Clock()
        app = App(builder, CHORD, {"t2": "x"}, **model)
        act, builder.focus_pane = builder.action, lambda pane: order.append("focus_pane")
        builder.action = lambda name, *args, **more: (order.append(name), act(name, *args, **more))[1]
        letters = M.Letters(builder, lambda method, params=None: (order.append(method), app(method, params))[1], wait,
                            pause=lambda seconds: (order.append("pause"), clock.pause(seconds))[1], clock=clock.now)
        record = letters.case("three-key", 0)
        keys = len(order) - 1 - order[::-1].index("debug.key")
        return record, order[keys + 1:order.index("tab.focus", keys) + 1], order[keys - 2:keys]

    def test_the_last_call_before_the_tools_own_acts_on_the_first_new_tab_is_the_read_of_the_park(self):
        # The focus of the new tabs' pane and the select are the tool's acts: a read after one of them is no read of
        # what the app did with no help. The journal's read comes before the last read of the park.
        record, after, before = self.ordered()
        self.assertTrue(record["pass"])
        self.assertEqual(after, ["pause", "debug.focus", "debug.new_tab", "debug.focus", "debug.journal", "debug.focus", "focus_pane", "tab.focus"])
        self.assertEqual(before, ["debug.journal", "debug.focus"])  # the journal's last number, then the park, before the keys

    def test_a_case_with_a_text_in_the_park_makes_no_act_but_reads_of_the_park_to_the_first_empty_read(self):
        record, after, _ = self.ordered(park={"parked": 1}, turns={4: {"typed": 1}})
        self.assertEqual(after, ["pause", "debug.focus", "debug.new_tab", "debug.focus", "pause", "debug.focus", "pause", "debug.focus",
                                 "debug.journal", "debug.focus", "focus_pane", "tab.focus"])
        self.assertEqual((record["pass"], record["waits_before_select"]), (True, 0))

    def test_a_record_has_the_journals_counts_before_the_select_and_the_first_new_tabs_engine(self):
        wrote = [page("t2", True), note("page commandFocus= el=input#secret-draft epoch=1"), note("page editing=1"), note("page keyTarget=input#secret-draft"),
                 page("t2", False), page("t3", True, "chromium"), note("page commandFocus= el=textarea#secret-draft epoch=1"), note("page editing=true"),
                 note("page editing=0"), note("wait find document=true focus=-"), note("wait end focus"), note("show pane=p", "t3"), {"marker": "secret-draft"}]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote)[0].case("three-key", 0)
        self.assertEqual(record.get("journal"), {"whole": True, "entries": 13, "page_entries": {"each_tab": [2, 1], "first_new_tab": 2},
                                                 "readiness": {"focus": 2, "editing_on": 2, "editing_off": 1, "key": 1, "wait": 1, "wait_end": 1},
                                                 "first_new_tab": {"focus_given": 1, "focus_taken": 1, "chromium_given": 0, "engines": ["webkit"]}})
        self.assertEqual((record.get("engine"), record["pass"]), ("webkit", True))
        # Counts and the app's engine word only: no element, no text of an entry.
        self.assertEqual([word for word in ("secret", "draft", "textarea", "epoch") if word in json.dumps(record)], [])

    def test_the_engine_is_the_last_word_and_each_change_is_in_the_record(self):
        wrote = [page("t2", True), page("t2", True), page("t2", True, "chromium-key"), page("t3", True, "chromium"), page("t2", False, "a text of the app")]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote)[0].case("three-key", 0)
        self.assertEqual((record["journal"]["first_new_tab"], record["engine"]),
                         ({"focus_given": 3, "focus_taken": 1, "chromium_given": 0, "engines": ["webkit", "chromium-key", "other"]}, "other"))
        # No entry of the first new tab, and the tool has the id of its page: no engine word, and that is no read
        # of an engine. With no id of its page: the word that the tool cannot read it (class PageId has its rows).
        wrote = [page("t3", True, "chromium")]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote, pages={"t2": PAGE})[0].case("three-key", 0)
        self.assertEqual((record["journal"]["first_new_tab"], record["engine"]), ({"focus_given": 0, "focus_taken": 0, "chromium_given": 0, "engines": []}, None))
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote)[0].case("three-key", 0)
        self.assertEqual((record["journal"]["first_new_tab"], record["engine"]), (M.UNREADABLE, M.UNREADABLE))

    def test_the_count_of_the_page_entries_of_each_tab_tells_no_entry_of_this_tab_from_no_page_entry(self):
        # With the id of the first new tab's page, `engine` None and 2 counts of 0 with entries of other ids: no
        # entry has an id of the first new tab. With no id of its page the tool cannot say that: the word, and the
        # counts of each id are the raw count (page entries there with none matched: the match can be wrong).
        # Counts only, the largest first, and no id of a tab.
        wrote = [page("t3", True, "chromium"), page("t3", False, "chromium"), page("t3", True, "chromium"), page("t1", False), note("page editing=1")]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote, pages={"t2": PAGE})[0].case("three-key", 0)
        self.assertEqual((record["journal"]["page_entries"], record["engine"]), ({"each_tab": [3, 1], "first_new_tab": 0}, None))
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote)[0].case("three-key", 0)
        self.assertEqual((record["journal"]["page_entries"], record["engine"]), ({"each_tab": [3, 1], "first_new_tab": M.UNREADABLE}, M.UNREADABLE))
        record = self.letters(CHORD, {"t2": "x"}, journal=[note("page editing=1")])[0].case("three-key", 0)
        self.assertEqual((record["journal"]["page_entries"], record["engine"]), ({"each_tab": [], "first_new_tab": M.UNREADABLE}, M.UNREADABLE))
        wrote = [page("t2", True), page("t2", True), page("t2", True, "chromium-key"), page("t3", True, "chromium"), page("t2", False, "a text of the app")]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote)[0].case("three-key", 0)
        self.assertEqual(record["journal"]["page_entries"], {"each_tab": [4, 1], "first_new_tab": 4})
        self.assertEqual([word for word in ("t1", "t2", "t3") if word in json.dumps(record["journal"])], [])
        # A page entry whose tab is no text (a list) is counted too, and stops no case.
        odd = [{"seq": 3, "kind": {"page": {"tab": ["a", "b"], "focused": True}}}]
        self.assertEqual(M.noted(odd, 2, "t2", PAGE)["page_entries"], {"each_tab": [1], "first_new_tab": 0})
        self.assertEqual(M.noted(odd, 2, "t2")["page_entries"], {"each_tab": [1], "first_new_tab": M.UNREADABLE})

    def test_the_count_of_the_open_new_tab_key_holds_at_the_last_read_is_in_the_record_and_changes_no_verdict(self):
        for holds, count in ((None, None), ([], 0), (["window-7", "window-9"], 2)):
            record = self.letters(CHORD, {"t2": "x"}, holds=holds)[0].case("three-key", 0)
            self.assertEqual((record["holds_before_select"], record["pass"], record.get("not_run")), (count, True, None), holds)
            self.assertNotIn("window-", json.dumps(record))

    def test_a_reply_whose_holds_are_no_list_gives_no_count_of_the_holds_and_changes_no_verdict(self):
        for holds in ({"window-7": 1}, "window-7", 2, True):
            record = self.letters(CHORD, {"t2": "x"}, holds=holds)[0].case("three-key", 0)
            self.assertEqual((record["holds_before_select"], record["pass"], record.get("not_run")), (None, True, None), holds)
            self.assertNotIn("window-", json.dumps(record))

    def test_an_entry_before_the_keys_is_not_counted_and_a_cut_read_says_so(self):
        # The model's journal has one focus note before each case's keys (the number 40).
        self.assertEqual(M.noted([{"seq": 40, "kind": note("page epoch=1")}, {"seq": 41, "kind": note("page epoch=2")}], 40, "t2")["readiness"]["focus"], 1)
        record = self.letters(CHORD, {"t2": "x"}, journal=[note("page editing=1")])[0].case("three-key", 0)
        self.assertEqual((record["journal"]["whole"], record["journal"]["entries"], record["journal"]["readiness"]["focus"]), (True, 1, 0))
        with mock.patch.object(M, "JOURNAL_LAST", 2):  # the read has the last 2 of the 4 entries of the case
            record = self.letters(CHORD, {"t2": "x"}, journal=[note("page epoch=2")] * 4)[0].case("three-key", 0)
        self.assertEqual((record["journal"]["whole"], record["journal"]["entries"], record["journal"]["readiness"]["focus"]), (False, 2, 2))
        self.assertEqual(M.noted([{"seq": 3}, "no dict", {"seq": 4, "kind": "no dict"}, {"seq": 5, "kind": {"content": "no dict"}}], 2, "t2")["entries"], 3)

    def journal(self, reply, first=False):
        """A case of three-key against an app whose `debug.journal` gives `reply` (an exception: the call raises it).
        `first`: the read before the keys gets the model's good reply, and only the read before the select `reply`."""
        builder, reads = Builder(), []
        app = App(builder, CHORD, {"t2": "x"})

        def rpc(method, params=None):
            if method != "debug.journal":
                return app(method, params)
            reads.append(method)
            if first and len(reads) == 1:
                return app(method, params)
            if isinstance(reply, Exception):
                raise reply
            return reply
        record = M.Letters(builder, rpc, wait, pause=lambda seconds: None).case("three-key", 0)
        self.assertEqual(len(reads), 2 if first else 1, reply)  # with no last number before the keys the tool reads no entries
        return record

    def test_an_app_with_no_journal_changes_no_verdict_and_the_record_says_why(self):
        stats = {"enabled": True, "lastSeq": 3}
        odd = [({"stats": {"enabled": True, "lastSeq": last}, "entries": []}, "no stats") for last in (True, float("nan"), float("inf"), float("-inf"), "41")]
        for reply, why in [(None, "no dict"), ({}, "no stats"), ({"error": "a text of the app"}, "error"), ({"stats": {**stats, "enabled": False}, "entries": []}, "off"),
                           ({"stats": {"enabled": True}, "entries": []}, "no stats"), (KeyError("a text of the app"), "KeyError")] + odd:
            for first in (False, True):  # the read before the keys fails too; or only the read before the select fails
                record = self.journal(reply, first)
                self.assertEqual((record.get("journal"), record.get("engine", 7)), ({"not_read": why}, None), (reply, first))
                self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"], record.get("places_not_read")), (True, None, "new tab's field", None), reply)
                self.assertNotIn("a text", json.dumps(record))
        record = self.journal({"stats": stats}, first=True)  # a good last number and no list of entries
        self.assertEqual((record["journal"], record["pass"]), ({"not_read": "no entries"}, True))
        self.assertEqual(self.letters(CHORD, {"t2": "x"}, journal=None)[0].case("three-key", 0)["journal"], {"not_read": "no stats"})

    def test_an_entry_whose_number_is_no_number_changes_no_verdict(self):
        # The app's number of an entry is a UInt64, so the app does not make this. The tool compares the number, and
        # a text or a list there must not make the case `not_run`: the journal changes no verdict.
        for seq in ("a text of the app", ["a text of the app"], {"a": 1}):
            entries = [{"seq": 41, "kind": note("page epoch=2")}, {"seq": seq, "kind": note("page epoch=3")}]
            with self.assertRaises(TypeError):
                M.noted(entries, 40, "t2")
            record = self.journal({"stats": {"enabled": True, "lastSeq": 42}, "entries": entries}, first=True)
            self.assertEqual((record["journal"], record["engine"]), ({"not_read": "TypeError"}, None), seq)
            self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"]), (True, None, "new tab's field"), seq)
            self.assertNotIn("a text", json.dumps(record))


class AfterSelect(unittest.TestCase):
    """`engine` None before the select does not say which engine has the first new tab's page (the app writes an
    entry only at a change of a page's focus). So a case reads the journal ONE more time, directly after its read
    of the window and before its selects of other tabs, and the record has the engine word of the entries after
    the last read before the select. A read only."""

    letters, journal = Case.letters, BeforeSelect.journal

    def test_a_record_has_the_first_new_tabs_engine_word_of_the_entries_after_the_last_read_before_the_select(self):
        # A page whose focus the app did not change before the select: no entry names it there, and the entry of
        # the select does. Counts and the app's engine word only: no id, no element, no text of an entry. The
        # entries of this row name the page by the tab's id, as the app does for a browser tab only, and the tool
        # has no id of the tab's page: with no such entry before the select the tool says that it cannot read it.
        # (The rows whose entries have the page's own id, as the app's are for a New Tab page: class PageId.)
        wrote = [page("t3", True, "chromium"), note("page editing=1")]
        after = [page("t3", False, "chromium"), page("t2", True, "chromium"), note("page commandFocus= el=input#secret-draft epoch=2"),
                 note("page editing=1"), page("t2", False, "chromium"), {"marker": "secret-draft"}]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote, after=after)[0].case("three-key", 0)
        self.assertEqual((record["engine"], record["journal"]["first_new_tab"]), (M.UNREADABLE, M.UNREADABLE))
        self.assertEqual((record.get("engine_after_select"), record["pass"]), ("chromium", True))
        self.assertEqual(record["journal_after_select"], {"whole": True, "entries": 6, "page_entries": {"each_tab": [2, 1], "first_new_tab": 2},
                                                          "readiness": {"focus": 1, "editing_on": 1, "editing_off": 0, "key": 0, "wait": 0, "wait_end": 0},
                                                          "first_new_tab": {"focus_given": 1, "focus_taken": 1, "chromium_given": 1, "engines": ["chromium"]}})
        self.assertEqual([word for word in ("secret", "draft", "epoch", "t2", "t3") if word in json.dumps(record["journal_after_select"])], [])
        # No page entry before the select and after it, and no id of the page: the word, and not None and 0.
        record = self.letters(CHORD, {"t2": "x"}, journal=[note("page editing=1")], after=[note("page editing=1")])[0].case("three-key", 0)
        self.assertEqual((record["engine"], record.get("engine_after_select", 7)), (M.UNREADABLE, M.UNREADABLE))
        self.assertEqual((record["journal_after_select"]["page_entries"], record["journal_after_select"]["readiness"]["editing_on"]),
                         ({"each_tab": [], "first_new_tab": M.UNREADABLE}, 1))
        # An entry before the last read before the select is not counted after it: its word is in `engine` only.
        record = self.letters(CHORD, {"t2": "x"}, journal=[page("t2", True, "chromium")], pages={"t2": PAGE})[0].case("three-key", 0)
        self.assertEqual((record["engine"], record.get("engine_after_select", 7)), ("chromium", None))
        self.assertEqual((record["journal_after_select"]["entries"], record["journal_after_select"]["whole"]), (0, True))
        # The last word of the entries after the select, each change in the record, and `other` for a word that the tool does not know.
        after = [page("t2", True, "chromium"), page("t2", True, "chromium-key"), page("t2", False, "a text of the app")]
        record = self.letters(CHORD, {"t2": "x"}, after=after)[0].case("three-key", 0)
        self.assertEqual((record["journal_after_select"]["first_new_tab"], record["engine_after_select"]),
                         ({"focus_given": 2, "focus_taken": 1, "chromium_given": 1, "engines": ["chromium", "chromium-key", "other"]}, "other"))
        self.assertNotIn("a text", json.dumps(record))
        # A read that was cut says so (the last 2 of the 4 entries after the select).
        with mock.patch.object(M, "JOURNAL_LAST", 2):
            record = self.letters(CHORD, {"t2": "x"}, after=[note("page epoch=2")] * 3 + [page("t2", True, "chromium")])[0].case("three-key", 0)
        self.assertEqual((record["journal_after_select"]["whole"], record["journal_after_select"]["entries"], record["engine_after_select"]), (False, 2, "chromium"))

    def whole(self, form, notes, texts, read=True, window=True, **model):
        """A case of `form`: (its record, each call of the app and each act of the tool in their order, the form's
        line of that one case). `read` False: a tool with no read of the journal after the select. `window` False:
        a tool with no read of the window (`debug.focus`) after the select."""
        builder, order, clock = Builder(), [], Clock()
        app = App(builder, notes, dict(texts), **model)  # a copy: the model writes the fields' texts into it
        app.clock, act = clock, builder.action
        builder.action = lambda name, *args, **more: (order.append(name), act(name, *args, **more))[1]
        letters = M.Letters(builder, lambda method, params=None: (order.append(method), app(method, params))[1], wait, pause=clock.pause, clock=clock.now)
        if not read:
            letters.after_select = lambda tab: {}
        if not window:
            letters.shown_page = lambda record, pane, tab: {}
        record = letters.case(form, 0)
        return record, order, M.verdict(form, [record])

    def test_the_read_after_the_select_comes_directly_after_the_read_of_the_window_and_changes_no_other_key_of_the_record(self):
        # The same case 2 times: with the tool's read after the select, and with a tool that has no such read. The
        # whole record but the 2 new keys, each other call and act in their order, and the form's line are the
        # same: the read is ONE call directly after the read of the window (which comes directly after the
        # verdict's read of the field), before the tool's selects of the other tabs for the reads of the places.
        late = {"park": {"parked": 1}, "park_end": {"typed": 1}}
        for form, notes, texts, model in (("three-key", CHORD, {"t2": "x"}, {}), ("three-key", CHORD, {"t2": "x"}, late), ("three-key", DROP, {}, {}),
                                          ("three-key", CHORD, {}, {"park": {"parked": 1}, "park_end": {"dropped_old": 1}}),
                                          ("from-chat", CHORD, {"t3": "x"}, {}), ("from-chat", CHORD, {"t3": "x"}, late), ("close-move", CHORD, {"t3": "x"}, {"motion": MOVE}),
                                          ("reselect", CHORD, {"t3": "x"}, {}), ("switch-next", CHORD, {}, {"lands": {"t1": "xx"}}),
                                          ("switch-previous", CHORD, {"t3": "x"}, {}), ("two-key", READY, {"t2": "x"}, {})):
            model = {**model, "journal": [note("page editing=1")], "after": [page("t2", True, "chromium"), page("t3", True, "chromium"), note("page editing=1")]}
            record, order, line = self.whole(form, notes, texts, **model)
            plain, before, line_before = self.whole(form, notes, texts, read=False, **model)
            self.assertEqual(sorted(set(record) - set(plain)), ["engine_after_select", "journal_after_select"], form)
            self.assertEqual({key: value for key, value in record.items() if key in plain}, plain, form)
            at = next(index for index, call in enumerate(order) if before[index] != call)
            self.assertEqual((order[at - 2:at + 1], order[:at] + order[at + 1:]), (["debug.new_tab", "debug.focus", "debug.journal"], before), form)
            self.assertEqual(("tab.focus" in order[at:], order[-1]), (True, "closeWorkspace"), form)  # each read of the places comes after it
            self.assertEqual((line, "pass" in plain, record["engine_after_select"]), (line_before, True, "chromium"), form)

    def test_the_entries_after_the_select_are_counted_from_the_last_read_of_the_journal_before_it(self):
        # A case with 2 waits reads the journal 2 times before its select. An entry that the app writes between
        # those 2 reads is of the time before the select: `engine` has its word, and the read after the select
        # does not count it. (The tool has the id of the tab's page: the 0 after the select is a count.)
        builder, reads, clock = Builder(), [], Clock()
        app = App(builder, CHORD, {"t2": "x"}, turns={3: {"parked": 1}, 5: {"typed": 1}}, after=[note("page editing=1")], pages={"t2": PAGE})
        app.clock = clock

        def rpc(method, params=None):
            reply = app(method, params)
            if method == "debug.journal":
                reads.append(reply["stats"]["lastSeq"])
                if len(reads) == 2:  # after the first of the 2 reads before the select (the read before the keys is the first of all)
                    app.write([page("t2", True)])
            return reply
        record = M.Letters(builder, rpc, wait, pause=clock.pause, clock=clock.now).case("three-key", 0)
        self.assertEqual((reads, record["pass"]), ([40, 40, 41, 42], True))
        self.assertEqual((record["engine"], record["journal"]["first_new_tab"]["focus_given"]), ("webkit", 1))
        found = record["journal_after_select"]
        self.assertEqual((record["engine_after_select"], found["entries"], found["first_new_tab"]["focus_given"], found["readiness"]["editing_on"]), (None, 1, 0, 1))

    def third(self, reply, count):
        """The report of `count` cases of three-key against an app whose third read of `debug.journal` in each case
        (the read after the select) gives `reply` (an exception: the call raises it)."""
        builder, reads = Builder(), []
        app = App(builder, CHORD, {"t2": "x", "t5": "x"}, after=[page("t2", True, "chromium"), page("t5", True, "chromium")])

        def rpc(method, params=None):
            if method != "debug.journal":
                return app(method, params)
            reads.append(method)
            if len(reads) % 3:
                return app(method, params)
            if isinstance(reply, Exception):
                raise reply
            return reply
        report = M.Letters(builder, rpc, wait, pause=lambda seconds: None).run(count, forms=("three-key",), say=lambda line: None)
        self.assertEqual(len(reads), 3 * count, reply)
        return report

    def test_a_failed_read_after_the_select_is_no_engine_word_with_the_why_and_ends_no_case_and_no_run(self):
        stats = {"enabled": True, "lastSeq": 43}
        odd = [{"seq": 42, "kind": note("page epoch=2")}, {"seq": "a text of the app", "kind": note("page epoch=3")}]
        for reply, why in ((None, "no dict"), ({}, "no stats"), ({"error": "a text of the app"}, "error"), ({"stats": {**stats, "enabled": False}, "entries": []}, "off"),
                           ({"stats": stats}, "no entries"), ({"stats": stats, "entries": odd}, "TypeError"), (KeyError("a text of the app"), "KeyError")):
            report = self.third(reply, 2)
            for record in report["cases"]:
                self.assertEqual((record.get("engine_after_select", 7), record.get("journal_after_select")), (None, {"not_read": why}), reply)
                self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"], record.get("places_not_read")), (True, None, "new tab's field", None), reply)
                self.assertEqual((record["engine"], record["journal"]["entries"]), (M.UNREADABLE, 0), reply)  # the read before the select is as it was
                self.assertNotIn("a text", json.dumps(record))
            self.assertEqual((report["forms"][0]["verdict"], report["forms"][0]["ran"]), ("PASS", 2), reply)

    def test_an_exception_of_the_read_after_the_select_leaves_the_case_as_it_is(self):
        # The case has its verdict and its places: an exception of the tool's own code at that read makes no `not_run`.
        real = M.Letters.entries_after

        def entries_after(self, mark, why, tab, page=None):
            if why == M.UNMARKED:
                raise RuntimeError("a text of the app")
            return real(self, mark, why, tab, page)
        with mock.patch.object(M.Letters, "entries_after", entries_after):
            record = self.letters(CHORD, {"t2": "x"}, after=[page("t2", True, "chromium")])[0].case("three-key", 0)
        self.assertEqual((record["engine_after_select"], record["journal_after_select"]), (None, {"not_read": "RuntimeError"}))
        self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"]), (True, None, "new tab's field"))
        self.assertNotIn("a text", json.dumps(record))

    def test_with_no_read_of_the_journal_before_the_select_the_tool_reads_no_entries_after_it(self):
        # `journal` counts the reads: 1 when the read before the keys fails, 2 when only the read before the select fails.
        self.assertEqual(M.UNMARKED, "no read before the select")
        for first in (False, True):
            record = self.journal(KeyError("a text of the app"), first)
            self.assertEqual((record["journal"], record.get("journal_after_select"), record.get("engine_after_select", 7)),
                             ({"not_read": "KeyError"}, {"not_read": M.UNMARKED}, None), first)
            self.assertEqual((record["pass"], record.get("not_run")), (True, None), first)
        # The same of a tool that made no read before a select: no call of the app.
        app = App(Builder(), CHORD, {})
        self.assertEqual(M.Letters(Builder(), app, wait).after_select("t2"), {"journal_after_select": {"not_read": M.UNMARKED}, "engine_after_select": None})
        self.assertEqual(app.calls, [])

    def test_a_case_that_is_not_run_before_its_select_has_no_key_of_the_read_after_it(self):
        # Before the select (no counts of the park; the app refuses the keys), at the select (the pane does not
        # show the tab), and at the verdict's read of the field (`stop`: that read raises).
        after = ("engine_after_select", "journal_after_select", "shown_page_has_chromium_focus", "page_is_the_windows_page_before_the_keys")
        for model, reads, stop in (({"counts": False}, 1, False), ({"refuse": "no Chromium page window for pane p"}, 1, False),
                                   ({"builder": Builder(refuse="No tab matches t2"), "wait": poll}, 2, False), ({}, 2, True)):
            letters, builder, app = self.letters(CHORD, {"t2": "x"}, after=[page("t2", True, "chromium")], pages={"t2": PAGE}, **model)
            if stop:  # after the case's keys only: the setup reads a field too
                real = letters.field
                letters.field = lambda: real() if not app.sequences else {}["a text of the app"]
            record = letters.case("three-key", 0)
            self.assertEqual(("not_run" in record, [key for key in after if key in record], "after_select" in record.get("keyboard", {})), (True, [], False), model)
            self.assertEqual(app.calls.count(("debug.journal", None)), reads, model)
            self.assertEqual((record["not_run"] == "the case stopped: KeyError", ("tab.focus", "tab:t2") in builder.actions and "park_wait" in record),
                             (stop, stop or model.get("wait") is poll), model)
        # Each case counts from its own last read before the select: the entries of the case before are not in it.
        letters, builder, app = self.letters(CHORD, {"t2": "x", "t5": "x"}, after=[page("t2", True, "chromium"), page("t5", True, "chromium")])
        first, second = letters.case("three-key", 0), letters.case("three-key", 1)
        self.assertEqual([(record["engine_after_select"], record["journal_after_select"]["entries"]) for record in (first, second)], [("chromium", 2)] * 2)


class PageId(unittest.TestCase):
    """The app's journal names a cmux page in Chromium by the id of the page's own Chromium tab, a random one, and
    not by the id of the pane's tab. The tool gets that id from the window's word in `debug.focus` after its
    select (ONE read), counts the first new tab's entries by it, and keeps no id in a record. From the replies of
    `debug.focus` that a case has, the record has the class of the view with the keyboard too."""

    letters, whole = Case.letters, AfterSelect.whole
    WEB, CHROMIUM = {"view": "PageWKWebView", "chromium_page_focus": False}, {"view": "ShellWindow", "chromium_page_focus": True}

    def test_a_page_that_the_journal_names_by_its_own_random_id_has_its_engine_word_after_the_select(self):
        # As the app does for a New Tab page in Chromium: each page entry has the page's own id. A match by the
        # tab's id finds no such entry: the tool of before had no engine word and 2 counts of 0 for each such case.
        self.assertEqual([tab for tab in ("t1", "t2", "t3") for name in EACH.values() if tab in name], [])
        after = [page(OTHER_PAGE, False, "chromium"), page(PAGE, True, "chromium"), note("page editing=1")]
        record = self.letters(CHORD, {"t2": "x"}, after=after, pages=EACH)[0].case("three-key", 0)
        self.assertEqual((record.get("engine_after_select"), record["pass"], record.get("not_run")), ("chromium", True, None))
        self.assertEqual(record["journal_after_select"]["first_new_tab"], {"focus_given": 1, "focus_taken": 0, "chromium_given": 1, "engines": ["chromium"]})
        self.assertEqual(record["journal_after_select"]["page_entries"], {"each_tab": [1, 1], "first_new_tab": 1})
        self.assertIs(record.get("shown_page_has_chromium_focus"), True)
        # Before the select the app wrote no entry of that page, and the tool has its id: a count of 0, no word.
        self.assertEqual((record["engine"], record["journal"]["first_new_tab"]["focus_given"], record["journal"]["page_entries"]["first_new_tab"]), (None, 0, 0))
        # The record keeps no id: no part of the id of a page.
        self.assertEqual([part for name in EACH.values() for part in name.split("-") if part in json.dumps(record)], [])

    def test_the_entries_before_the_select_are_counted_again_with_the_pages_id(self):
        # The tool has the id only after its select. The entries of the last read before the select are in memory
        # to that read: `journal` and `engine` then have the counts by the page's id, each other part of `journal`
        # is as it was, and the tool makes no read of the journal more.
        wrote = [page(PAGE, True, "chromium"), page(OTHER_PAGE, True, "chromium"), page(PAGE, False, "chromium"), note("page editing=1")]
        record, order, _ = self.whole("three-key", CHORD, {"t2": "x"}, journal=wrote, pages=EACH)
        plain, _, _ = self.whole("three-key", CHORD, {"t2": "x"}, window=False, journal=wrote, pages=EACH)
        self.assertEqual((plain["engine"], plain["journal"]["first_new_tab"], plain["journal"]["page_entries"]),
                         (M.UNREADABLE, M.UNREADABLE, {"each_tab": [2, 1], "first_new_tab": M.UNREADABLE}))
        self.assertEqual((record["engine"], record["journal"]["first_new_tab"], record["journal"]["page_entries"]),
                         ("chromium", {"focus_given": 1, "focus_taken": 1, "chromium_given": 1, "engines": ["chromium"]}, {"each_tab": [2, 1], "first_new_tab": 2}))
        same = ("whole", "entries", "readiness")
        self.assertEqual(({key: record["journal"][key] for key in same}, sorted(record["journal"])), ({key: plain["journal"][key] for key in same}, sorted(plain["journal"])))
        self.assertEqual((order.count("debug.journal"), record["journal_after_select"]["entries"]), (3, 0))  # before the keys, before the select, after it

    def test_with_no_id_of_the_page_the_record_has_the_word_and_no_count_of_0(self):
        # The window names no Chromium page after the select: the page is in a WebKit view (`pages` has no such
        # tab), or the app gave its Chromium page no page focus (`lost`): False. A reply with no word of a window,
        # or of the window's first responder: None. The counts of each id are there: the raw count of the entries.
        self.assertEqual(M.UNREADABLE, "not readable for a cmux page in Chromium")
        wrote, after = [page(PAGE, True, "chromium")], [page(PAGE, False, "chromium"), page(OTHER_PAGE, True, "chromium")]
        for model, has in (({"pages": {"t3": OTHER_PAGE}}, False), ({"pages": EACH, "lost": ("t2",)}, False), ({}, None), ({"focus": True}, None)):
            record = self.letters(CHORD, {"t2": "x"}, journal=wrote, after=after, **model)[0].case("three-key", 0)
            self.assertIs(record.get("shown_page_has_chromium_focus", 7), has, model)
            self.assertEqual((record["engine"], record["engine_after_select"]), (M.UNREADABLE, M.UNREADABLE), model)
            self.assertEqual((record["journal"]["first_new_tab"], record["journal"]["page_entries"]), (M.UNREADABLE, {"each_tab": [1], "first_new_tab": M.UNREADABLE}), model)
            self.assertEqual((record["journal_after_select"]["first_new_tab"], record["journal_after_select"]["page_entries"]),
                             (M.UNREADABLE, {"each_tab": [1, 1], "first_new_tab": M.UNREADABLE}), model)
            self.assertEqual((record["pass"], record.get("not_run"), record.get("places_not_read")), (True, None, None), model)
        # An entry with the tab's id (the app writes such an entry for a browser tab) is counted with no id of a page.
        record = self.letters(CHORD, {"t2": "x"}, after=[page("t2", True, "chromium")])[0].case("three-key", 0)
        self.assertEqual((record["engine"], record["engine_after_select"], record["journal_after_select"]["page_entries"]["first_new_tab"]), (M.UNREADABLE, "chromium", 1))

    def test_the_tool_takes_the_windows_id_only_when_the_focus_model_names_the_first_new_tab(self):
        # The window's Chromium page with the page focus is the page of the focus model's tab. With another tab
        # there, or none, the id is not of the first new tab: the tool counts no entry by it, and the record's
        # `keyboard` has the window's own word.
        for aim in ("t3", None):
            record = self.letters(CHORD, {"t2": "x"}, after=[page(PAGE, True, "chromium")], pages=EACH, aims={"t2": aim})[0].case("three-key", 0)
            self.assertEqual((record["shown_page_has_chromium_focus"], record["engine_after_select"], record["keyboard"]["after_select"]), (False, M.UNREADABLE, self.CHROMIUM), aim)
        # A window with no word of its focus model's tab: no read, and that is not `no`.
        window = {"topology": [{"pane": "p", "selected": "t2"}], "appkit": {"first_responder": "ShellWindow", "child_window_page": PAGE}}
        for model, has in (({}, None), ({"model": "no dict"}, None), ({"model": {}}, None), ({"model": {"resolved_tab": "t2"}}, True), ({"model": {"resolved_tab": None}}, False)):
            letters = M.Letters(Builder(), lambda method, params=None: {"windows": [{**window, **model}]}, wait)
            self.assertEqual(letters.shown_page({}, "p", "t2"),
                             {"keyboard": {"after_select": self.CHROMIUM}, "shown_page_has_chromium_focus": has, "page_is_the_windows_page_before_the_keys": None}, model)
            self.assertEqual(letters.page, PAGE if has else None, model)

    MOVED = {"t1": PAGE, "t2": PAGE, "t3": OTHER_PAGE}  # the first new tab has the page view of the tab that the pane showed before the keys

    def test_a_first_new_tab_with_the_page_that_the_window_had_before_the_keys_says_so(self):
        # The id names a page VIEW, not a tab. 2 states of the app give this one reply after the select (the id of
        # before the keys, with a focus model that names the first new tab): the app gave the older tab's view to
        # the first new tab, or the window still names the older tab's page. The tool cannot part them: yes.
        wrote, after = [page(PAGE, True, "chromium"), page(OTHER_PAGE, True, "chromium")], [page(PAGE, False, "chromium")]
        record = self.letters(CHORD, {"t2": "x"}, journal=wrote, after=after, pages=self.MOVED)[0].case("three-key", 0)
        self.assertEqual((record.get("page_is_the_windows_page_before_the_keys", 7), record["shown_page_has_chromium_focus"]), (True, True))
        # The counts and the 2 engine words are as with each id: they are of that ONE view.
        self.assertEqual((record["engine"], record["journal"]["page_entries"], record["engine_after_select"]), ("chromium", {"each_tab": [1, 1], "first_new_tab": 1}, "chromium"))
        self.assertEqual((record["pass"], record.get("not_run")), (True, None))
        self.assertEqual([part for name in EACH.values() for part in name.split("-") if part in json.dumps(record)], [])  # the id of before the keys is in no record

    def test_a_first_new_tab_with_another_page_than_the_windows_page_before_the_keys_says_no(self):
        # Another id than before the keys (each tab has its own page), and a window that named no Chromium page
        # before the keys (the tab before has its page in a WebKit view): no.
        for pages in (EACH, {"t2": PAGE, "t3": OTHER_PAGE}):
            record = self.letters(CHORD, {"t2": "x"}, journal=[page(PAGE, True, "chromium")], pages=pages)[0].case("three-key", 0)
            self.assertEqual((record.get("page_is_the_windows_page_before_the_keys", 7), record["shown_page_has_chromium_focus"], record["engine"]), (False, True, "chromium"), pages)
        # The id of before the keys is of its own case: 2 cases, no in the first (2 ids) and yes in the second.
        letters, builder, app = self.letters(CHORD, {"t2": "x", "t5": "x"}, pages={"t1": OTHER_PAGE, "t2": PAGE, "t4": EACH["t4"], "t5": EACH["t4"]})
        self.assertEqual([letters.case("three-key", index).get("page_is_the_windows_page_before_the_keys", 7) for index in (0, 1)], [False, True])

    def test_with_no_id_after_the_select_or_no_read_before_the_keys_the_record_does_not_say_it(self):
        # No id after the select: a page in a WebKit view, a focus model that names another tab, a failed read, a
        # reply with no word of the window's first responder. None, and that is not `no`.
        for model in ({"pages": {"t1": PAGE}}, {"pages": self.MOVED, "aims": {"t2": "t3"}}, {"pages": self.MOVED, "dead": (1,)}, {"focus": True}):
            record = self.letters(CHORD, {"t2": "x"}, **model)[0].case("three-key", 0)
            self.assertEqual((record.get("page_is_the_windows_page_before_the_keys", 7), record["pass"], record.get("not_run")), (None, True, None), model)
        # No read before the keys (a tool that read no window then): None with an id after the select too. With a
        # read: yes for the same id, no for another one and for a window that named no Chromium page.
        window = {"topology": [{"pane": "p", "selected": "t2"}], "appkit": {"first_responder": "ShellWindow", "child_window_page": PAGE}, "model": {"resolved_tab": "t2"}}
        letters = M.Letters(Builder(), lambda method, params=None: {"windows": [window]}, wait)
        self.assertEqual((letters.shown_page({}, "p", "t2")["page_is_the_windows_page_before_the_keys"], letters.page), (None, PAGE))
        for before, same in ((PAGE, True), (OTHER_PAGE, False), (None, False), (M.UNSEEN, None)):
            letters.page_before = before
            self.assertIs(letters.shown_page({}, "p", "t2")["page_is_the_windows_page_before_the_keys"], same, before)
        # A case whose read before the keys names no window of the pane: None, with an id after the select.
        builder = Builder()
        app = App(builder, CHORD, {"t2": "x"}, pages=self.MOVED)
        reads = []

        def blind(method, params=None):  # the case's first read of `debug.focus` is the one before its keys
            reply = app(method, params)
            if method == "debug.focus":
                reads.append(len(app.sequences))
            return {**reply, "windows": []} if method == "debug.focus" and len(reads) == 1 else reply
        record = M.Letters(builder, blind, wait, pause=lambda seconds: None).case("three-key", 0)
        self.assertEqual(reads[0], 0)  # no key sequence was sent before that read
        self.assertEqual((record["keyboard"]["before"], record.get("page_is_the_windows_page_before_the_keys", 7), record["shown_page_has_chromium_focus"]),
                         ({"not_read": M.NO_WINDOW}, None, True))

    def test_a_record_has_the_class_of_the_view_with_the_keyboard_before_and_after_the_keys_and_after_the_select(self):
        # From the 2 replies of `debug.focus` that a case reads before and after its keys, and from its ONE read
        # after the select. A class name and yes / no only: no id, no other text of the app.
        record = self.letters(CHORD, {"t2": "x"}, pages={"t2": PAGE})[0].case("three-key", 0)
        self.assertEqual((record["keyboard"], record["shown_page_has_chromium_focus"]), ({"before": self.WEB, "after": self.WEB, "after_select": self.CHROMIUM}, True))
        record = self.letters(CHORD, {"t2": "x"}, pages={"t1": EACH["t1"], "t3": OTHER_PAGE})[0].case("three-key", 0)
        self.assertEqual((record["keyboard"], record["shown_page_has_chromium_focus"]), ({"before": self.CHROMIUM, "after": self.CHROMIUM, "after_select": self.WEB}, False))
        record = self.letters(CHORD, {"t2": "x"}, pages={"t1": EACH["t1"]})[0].case("three-key", 0)  # the word after the keys is of the reply after them
        self.assertEqual((record["keyboard"], record["shown_page_has_chromium_focus"]), ({"before": self.CHROMIUM, "after": self.WEB, "after_select": self.WEB}, False))
        for view, word in ((None, None), ("a text of the app", "other"), ("", "other"), (7, "other"), (["PageWKWebView"], "other"), ("A" * 81, "other"), ("A" * 80, "A" * 80),
                           ("NSKVONotifying_PageWKWebView", "NSKVONotifying_PageWKWebView"), ("Module.View<Kind>", "Module.View<Kind>")):
            record = self.letters(CHORD, {"t2": "x"}, pages=EACH, views=dict.fromkeys(("t1", "t2", "t3"), view))[0].case("three-key", 0)
            self.assertEqual([record["keyboard"][at]["view"] for at in ("before", "after", "after_select")], [word] * 3, view)
            self.assertEqual((record["pass"], record.get("not_run"), "a text" in json.dumps(record)), (True, None, False), view)
        # A case that is `not_run` after its keys has the 2 words of before its select.
        record = self.letters(CHORD, {"t2": "x"}, pages=EACH, counts=False)[0].case("three-key", 0)
        self.assertEqual(("not_run" in record, record.get("keyboard")), (True, {"before": self.CHROMIUM, "after": self.CHROMIUM}))

    def test_a_reply_with_no_window_of_the_pane_or_of_an_odd_form_is_no_read_of_the_keyboards_view(self):
        pane, good = [{"pane": "p", "selected": "t2"}], {"first_responder": "ShellWindow", "child_window_page": PAGE}
        for focus, why in (({}, M.NO_WINDOW), (None, M.NO_WINDOW), ({"windows": "no list"}, M.NO_WINDOW), ({"windows": ["no dict"]}, M.NO_WINDOW),
                           ({"windows": [{"topology": [{"pane": "q"}], "appkit": good}]}, M.NO_WINDOW), ({"windows": [{"topology": pane}]}, M.NO_APPKIT),
                           ({"windows": [{"topology": pane, "appkit": "no dict"}]}, M.NO_APPKIT), ({"windows": [{"topology": pane, "appkit": {"first_responder": "ShellWindow"}}]}, M.NO_APPKIT),
                           ({"windows": [{"topology": pane, "appkit": {"child_window_page": PAGE}}]}, M.NO_APPKIT), ({"windows": [{"topology": 7, "appkit": good}]}, "TypeError")):
            self.assertEqual(M.keyboard(focus, "p"), ({"not_read": why}, None, None), focus)
        self.assertEqual((M.NO_WINDOW, M.NO_APPKIT), ("no window names the pane", "the window has no word on its first responder"))
        # The window that names the pane, of 2 windows. An id that is no text, or an empty one, is no id.
        two = {"windows": [{"topology": [{"pane": "q"}], "appkit": {"first_responder": "PageWKWebView", "child_window_page": None}, "model": {"resolved_tab": "came"}},
                           {"topology": ["no dict"] + pane, "appkit": good, "model": {"resolved_tab": "t2"}}]}
        self.assertEqual((M.keyboard(two, "p"), M.keyboard(two, "q")), ((self.CHROMIUM, PAGE, "t2"), (self.WEB, None, "came")))
        for odd in (7, "", ["a"], True):
            found = M.keyboard({"windows": [{"topology": pane, "appkit": {**good, "child_window_page": odd}}]}, "p")
            self.assertEqual(found, ({"view": "ShellWindow", "chromium_page_focus": False}, None, M.UNSAID), odd)

    def test_a_failed_read_of_the_window_after_the_select_ends_no_case_and_no_run_and_changes_no_verdict(self):
        model = {"journal": [page(PAGE, True, "chromium")], "after": [page(PAGE, True, "chromium"), page("t2", False), page("t5", False)], "pages": EACH, "dead": (1,)}
        letters, builder, app = self.letters(CHORD, {"t2": "x", "t5": "x"}, **model)
        report = letters.run(2, forms=("three-key",), say=lambda line: None)
        for record in report["cases"]:
            self.assertEqual((record["keyboard"]["after_select"], record.get("shown_page_has_chromium_focus", 7)), ({"not_read": "KeyError"}, None))
            self.assertEqual((record["keyboard"]["before"], record["keyboard"]["after"]), (self.CHROMIUM, self.CHROMIUM))
            # No id: the entries with the page's id are not read, and the entry with the tab's id is counted.
            self.assertEqual((record["engine"], record["engine_after_select"], record["journal_after_select"]["first_new_tab"]["focus_taken"]), (M.UNREADABLE, "webkit", 1))
            self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"], record.get("places_not_read")), (True, None, "new tab's field", None))
            self.assertNotIn("a text", json.dumps(record))
        self.assertEqual((report["forms"][0]["verdict"], report["forms"][0]["ran"]), ("PASS", 2))
        # An exception of the tool's own count with the id: the same, and the tool uses no id after it.
        real = M.noted

        def noted(entries, mark, tab, page=None):
            if page is not None:
                raise RuntimeError("a text of the app")
            return real(entries, mark, tab, page)
        with mock.patch.object(M, "noted", noted):
            record = self.letters(CHORD, {"t2": "x"}, **{**model, "dead": ()})[0].case("three-key", 0)
        self.assertEqual((record["keyboard"]["after_select"], record["shown_page_has_chromium_focus"], record["engine"]), ({"not_read": "RuntimeError"}, None, M.UNREADABLE))
        self.assertEqual((record["pass"], record.get("not_run"), record["engine_after_select"], "a text" in json.dumps(record)), (True, None, "webkit", False))

    def test_the_read_of_the_window_is_one_call_after_the_verdicts_read_and_changes_no_other_key_of_the_record(self):
        # The same case 2 times: with the tool's read of the window after the select, and with a tool that has no
        # such read. The record has ONE key more, the 4 keys of the journal have the counts by the page's id,
        # `keyboard` has one part more, and each other key is the same (the park's counts at the case's end too:
        # also for a case with a text in the park). The call comes directly after the verdict's read of the field,
        # before the tool's selects of the other tabs. The form's line is the same.
        late = {"park": {"parked": 1}, "park_end": {"typed": 1}}
        for form, notes, texts, model, tab in (("three-key", CHORD, {"t2": "x"}, {}, "t2"), ("three-key", CHORD, {"t2": "x"}, late, "t2"), ("three-key", DROP, {}, {}, "t2"),
                                               ("three-key", CHORD, {}, {"park": {"parked": 1}, "park_end": {"dropped_old": 1}}, "t2"),
                                               ("from-chat", CHORD, {"t3": "x"}, {}, "t3"), ("from-chat", CHORD, {"t3": "x"}, late, "t3"),
                                               ("close-move", CHORD, {"t3": "x"}, {"motion": MOVE}, "t3"), ("reselect", CHORD, {"t3": "x"}, {}, "t3"),
                                               ("switch-next", CHORD, {}, {"lands": {"t1": "xx"}}, "t3"), ("switch-previous", CHORD, {"t3": "x"}, {}, "t3"),
                                               ("two-key", READY, {"t2": "x"}, {}, "t2")):
            model = {**model, "pages": EACH, "journal": [note("page editing=1"), page(EACH[tab], True, "chromium")],
                     "after": [page(EACH[tab], False, "chromium"), page(EACH[tab], True, "chromium-key"), note("page editing=1")]}
            record, order, line = self.whole(form, notes, texts, **model)
            plain, before, line_before = self.whole(form, notes, texts, window=False, **model)
            self.assertEqual(sorted(set(record) - set(plain)), ["page_is_the_windows_page_before_the_keys", "shown_page_has_chromium_focus"], form)
            self.assertIs(record["page_is_the_windows_page_before_the_keys"], False, form)  # each tab of the model has its own page
            self.assertEqual(sorted(key for key in plain if record[key] != plain[key]), ["engine", "engine_after_select", "journal", "journal_after_select", "keyboard"], form)
            self.assertEqual((record["keyboard"], record["shown_page_has_chromium_focus"]), ({**plain["keyboard"], "after_select": self.CHROMIUM}, True), form)
            self.assertEqual((plain["engine"], plain["engine_after_select"], record["engine"], record["engine_after_select"]), (M.UNREADABLE, M.UNREADABLE, "chromium", "chromium-key"), form)
            at = next(index for index, call in enumerate(order) if before[index] != call)
            self.assertEqual((order[at - 1], order[at], before[at], order[:at] + order[at + 1:]), ("debug.new_tab", "debug.focus", "debug.journal", before), form)
            self.assertEqual(before[at + 1], "tab.focus", form)  # the journal's read after the select, then the first select of another tab
            self.assertEqual((line, "pass" in plain, "park" in plain), (line_before, True, True), form)

    def test_an_entry_of_the_first_new_tabs_view_after_a_select_of_another_tab_is_not_in_the_counts_after_the_select(self):
        # The id names a page VIEW. The reads of the places select the case's other tabs. A pane that then shows a
        # New Tab tab with no view can take the first new tab's view when nobody used it (its field is empty), and
        # the app gives that view the page focus: entries with the SAME id, of the view while another tab has it.
        # The read after the select comes before those selects: its counts have the entry of the select only.
        # THE MODEL DOES MORE THAN THE APP: it writes its `moved` entries at ANY change of the shown tab after the
        # verdict's read of the field; the app gives a view away only when nobody used it and no pane shows its
        # tab. The field here is empty, so this state is one that the app can have. The row proves the ORDER of
        # the tool's calls only: it does not test the app's rule, and no row has a tab with a letter that keeps
        # its view.
        after, moved = [page(PAGE, True, "chromium-key")], [page(PAGE, False, "chromium"), page(PAGE, True, "chromium")]
        for form, notes in (("three-key", CHORD), ("two-key", READY)):
            letters, builder, app = self.letters(notes, {}, after=after, moved=moved, pages=self.MOVED)
            record = letters.case(form, 0)
            found = record["journal_after_select"]
            self.assertEqual((found["entries"], found["first_new_tab"], record["engine_after_select"]),
                             (1, {"focus_given": 1, "focus_taken": 0, "chromium_given": 0, "engines": ["chromium-key"]}, "chromium-key"), form)
            # The model wrote the 2 entries of the moved view after that read: the journal has them at the case's end.
            self.assertEqual(([entry["kind"] for entry in app.entries[-2:]], app.seq), (moved, 43), form)
            self.assertEqual((record.get("not_run"), record.get("places_not_read"), record["shown_page_has_chromium_focus"], record["field"]), (None, None, True, ""), form)
            self.assertIn(("tab.focus", "tab:t1"), builder.actions, form)  # the tool's select of the tab before

    def test_an_entry_between_the_apps_2_reads_of_a_reply_is_counted_one_time(self):
        # The app reads the journal's last number and its entries one after the other: an entry that came between
        # them is in the reply with a number above `lastSeq`. A cut by `lastSeq` alone counts it before the select
        # and after it (and, at the read before the keys, as an entry of the case).
        self.assertEqual(M.last_number({"stats": {"lastSeq": 41}, "entries": [{"seq": 41}, {"seq": 42}]}), 42)
        self.assertEqual(M.last_number({"stats": {"lastSeq": 43}, "entries": [{"seq": 41}, {"seq": 42}]}), 43)
        for entries in (None, "no list", [], ["no dict", {"seq": "a text"}, {"seq": True}, {"seq": float("nan")}, {"seq": float("inf")}, {"seq": [50]}, {}]):
            self.assertEqual(M.last_number({"stats": {"lastSeq": 41}, "entries": entries}), 41, entries)
        self.assertEqual(M.last_number({"stats": {"lastSeq": 0}, "entries": [{"seq": True}]}), 0)  # a bool is no number of an entry
        for late, counts in ((2, (1, 0)), (1, (0, 0))):  # at the read before the select; at the read before the keys
            builder, reads = Builder(), []
            app = App(builder, CHORD, {"t2": "x"}, pages=EACH)

            def rpc(method, params=None):
                if method != "debug.journal":
                    return app(method, params)
                reads.append(method)
                if len(reads) != late:
                    return app(method, params)
                app.write([page(PAGE, True, "chromium")])
                reply = app(method, params)
                return {**reply, "stats": {**reply["stats"], "lastSeq": reply["stats"]["lastSeq"] - 1}}
            record = M.Letters(builder, rpc, wait, pause=lambda seconds: None).case("three-key", 0)
            found = (record["journal"]["first_new_tab"]["focus_given"], record["journal_after_select"]["first_new_tab"]["focus_given"])
            self.assertEqual((found, len(reads), record["pass"]), (counts, 3, True), late)

    def test_only_a_give_with_the_word_chromium_says_that_the_app_gave_the_page_its_focus(self):
        # An entry that takes the focus has the word `chromium` too, and the app writes an entry with a `-key`
        # word by the place of a window that became key: the last engine word alone is no proof of a give.
        both = [page(PAGE, True, "chromium"), page(PAGE, False, "chromium"), page(PAGE, True, "chromium"), page(OTHER_PAGE, True, "chromium")]
        for after, word, given, chromium in (([page(PAGE, False, "chromium")], "chromium", 0, 0), ([page(PAGE, True, "chromium-key")], "chromium-key", 1, 0),
                                             ([page(PAGE, True, "chromium-unchosen-key")], "chromium-unchosen-key", 1, 0), ([page(PAGE, True, "webkit")], "webkit", 1, 0),
                                             ([page(PAGE, 1, "chromium")], "chromium", 0, 0), (both, "chromium", 2, 2)):
            record = self.letters(CHORD, {"t2": "x"}, after=after, pages=EACH)[0].case("three-key", 0)
            first = record["journal_after_select"]["first_new_tab"]
            self.assertEqual((record["engine_after_select"], first["focus_given"], first["chromium_given"]), (word, given, chromium), after)

    def test_a_failed_second_read_of_the_journal_before_the_select_gives_no_read_after_it(self):
        # A case with 2 waits reads the journal 2 times before its select. The second one fails: the tool has no
        # last number of the last read before the select (the number of the first one is not of it), it reads no
        # entries after the select, and it counts no kept entries again.
        builder, reads, clock = Builder(), [], Clock()
        app = App(builder, CHORD, {"t2": "x"}, turns={3: {"parked": 1}, 5: {"typed": 1}}, after=[page(PAGE, True, "chromium")], pages=EACH)
        app.clock = clock

        def rpc(method, params=None):
            if method == "debug.journal":
                reads.append(method)
                if len(reads) == 3:
                    raise KeyError("a text of the app")
            return app(method, params)
        record = M.Letters(builder, rpc, wait, pause=clock.pause, clock=clock.now).case("three-key", 0)
        self.assertEqual((len(reads), record["journal"], record["engine"]), (3, {"not_read": "KeyError"}, None))
        self.assertEqual((record["journal_after_select"], record["engine_after_select"]), ({"not_read": "no read before the select"}, None))
        self.assertEqual((record["pass"], record.get("not_run"), record["shown_page_has_chromium_focus"], "a text" in json.dumps(record)), (True, None, True, False))

    def test_a_case_does_not_use_the_id_of_the_page_of_the_case_before(self):
        # 2 cases: the first new tab of the first has its page in Chromium, that of the second in a WebKit view.
        # The app writes an entry with the first page's id in each case.
        letters, builder, app = self.letters(CHORD, {"t2": "x", "t5": "x"}, after=[page(PAGE, True, "chromium")], pages={"t2": PAGE})
        first, second = letters.case("three-key", 0), letters.case("three-key", 1)
        self.assertEqual([(record["shown_page_has_chromium_focus"], record["engine_after_select"], record["journal_after_select"]["page_entries"]) for record in (first, second)],
                         [(True, "chromium", {"each_tab": [1], "first_new_tab": 1}), (False, M.UNREADABLE, {"each_tab": [1], "first_new_tab": M.UNREADABLE})])


class Wait(unittest.TestCase):
    """The park keeps a text for 2 s, and the tool's select comes sooner. So a case with a text in the park makes no
    act but reads of the park, to the first read with no text or to 4 s after its last key: an app that types
    the text by itself in that time can pass. The park's 2 s are of the app's clock (from its own dispatch of the
    key), and the app's drop of a text at a read ends the wait: the 4 s are for a text that stays on its way. The
    model's clock: a pause of the tool takes time (and a read that a row names as slow), the 3 keys take 0.07 s,
    and the first read of the park comes 0.77 s after the app's reply to the keys."""

    letters, ordered = Case.letters, BeforeSelect.ordered

    def test_a_text_that_the_app_types_by_itself_in_the_parks_time_passes(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, turns={4: {"typed": 1}})
        record = letters.case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record.get("letter_also"), record["waits_before_select"]), (True, "new tab's field", None, 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 4, "empty_s": 0.97, "last_s": 0.97})
        self.assertEqual([record["park"][at]["typed"] for at in ("before", "after", "select", "end")], [0, 0, 1, 1])
        self.assertEqual(M.verdict("three-key", [record])["verdict"], "PASS")

    def test_a_text_that_stays_in_the_park_to_the_end_of_the_wait_is_no_pass(self):
        letters, builder, app = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, park_end={"typed": 1})
        record = letters.case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record.get("letter_also"), record["waits_before_select"]),
                         (False, "typed only after the select", ["new tab's field"], 1))
        # One read each 0.1 s from 0.77 s to the first read at 4.07 s (4 s after the last key), then the last read.
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 35, "empty_s": None, "last_s": 4.07})
        keys = [round(pause, 3) for pause in app.clock.pauses].index(0.77)
        self.assertEqual(app.clock.pauses[keys + 1:keys + 35], [M.WAIT_STEP_S] * 33 + [0.4])  # 0.4: the pause after the select
        self.assertEqual((M.WAIT_S, M.WAIT_STEP_S), (4.0, 0.1))

    def test_the_wait_ends_a_fixed_time_after_the_last_key_of_a_longer_sequence(self):
        # A switch form: its key and the wait before the 3 keys take 0.182 s, so the last read is 4.182 s after the call.
        letters, builder, app = self.letters(CHORD, {"t3": "x"}, park={"parked": 1}, park_end={"typed": 1})
        record = letters.case("switch-previous", 0)
        self.assertEqual((record.get("not_run"), record["pass"], record["letter_is"]), (None, False, "typed only after the select"))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.882, "reads": 35, "empty_s": None, "last_s": 4.182})

    def test_the_wait_goes_on_after_2_s_of_the_tools_clock_for_a_text_that_the_app_parked_late(self):
        # The app dispatches a key when its main thread gets to it, so the 2 s of a parked text can end later than
        # 2 s after the key's time in the sequence: a text that the app types by itself 2.57 s after the reply is
        # the app's own work, and the first read with no text ends the wait.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, turns={20: {"typed": 1}})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (True, "new tab's field", 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 20, "empty_s": 2.57, "last_s": 2.57})
        # The app's own drop of a text that only waited ends the wait too: the word of that end, and not the late word.
        record = self.letters(CHORD, {}, park={"parked": 1}, turns={22: {"dropped_old": 1}})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "dropped after the bound", 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 22, "empty_s": 2.77, "last_s": 2.77})

    def test_the_wait_is_the_same_in_each_form(self):
        for form, first, notes in (("reselect", "t3", CHORD), ("close-move", "t3", CHORD), ("from-chat", "t3", CHORD), ("three-key", "t2", CHORD),
                                   ("switch-next", "t3", CHORD), ("switch-previous", "t3", CHORD), ("two-key", "t2", READY)):
            # A text that stays: one read each 0.1 s to 4 s after the last key (3.3 s after the first read), then the last read.
            record = self.letters(notes, {first: "x"}, park={"parked": 1}, park_end={"typed": 1}, motion=MOVE)[0].case(form, 0)
            self.assertEqual((record.get("not_run"), record["pass"], record["letter_is"], record["waits_before_select"]),
                             (None, False, "typed only after the select", 1), form)
            wait = record["park_wait"]
            self.assertEqual((wait["first"], wait["reads"], wait["empty_s"], wait["last_s"]), (1, 35, None, round(wait["first_s"] + 3.3, 3)), form)
            # A text that the app types by itself 0.2 s after the first read: a pass.
            record = self.letters(notes, {first: "x"}, park={"parked": 1}, turns={4: {"typed": 1}}, motion=MOVE)[0].case(form, 0)
            self.assertEqual((record.get("not_run"), record["pass"], record["letter_is"], record["waits_before_select"]), (None, True, "new tab's field", 0), form)
            wait, at = record["park_wait"], round(record["park_wait"]["first_s"] + 0.2, 3)
            self.assertEqual((wait["first"], wait["reads"], wait["empty_s"], wait["last_s"]), (1, 4, at, at), form)

    def test_a_first_read_of_the_park_that_comes_after_the_bound_gets_no_wait(self):
        # A slow call before it (the read of the hold's log takes 4 s): the first read is 4.77 s after the reply.
        letters, builder, app = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, park_end={"typed": 1}, slow={1: 4.0})
        record = letters.case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "typed only after the select", 1))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 4.77, "reads": 2, "empty_s": None, "last_s": 4.77})
        keys = [round(pause, 3) for pause in app.clock.pauses].index(0.77)
        self.assertEqual(app.clock.pauses[keys + 1], 0.4)  # no pause of the wait: the next one is the pause after the select
        # With no text at that late read the case passes, as each case with no text in the park.
        record = self.letters(CHORD, {"t2": "x"}, slow={1: 4.0})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["park_wait"]), (True, {"first": 0, "first_s": 4.77, "reads": 2, "empty_s": 4.77, "last_s": 4.77}))

    def test_a_slow_read_of_the_wait_that_ends_after_the_bound_ends_the_wait(self):
        # The second read of the park takes 5 s: it ends 5.87 s after the reply, and no read of the wait comes after it.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, park_end={"typed": 1}, slow={3: 5.0})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "typed only after the select", 1))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 3, "empty_s": None, "last_s": 5.87})
        # The text left the park at that slow read: no text at the last read is a pass after the bound too.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, turns={3: {"typed": 1}}, slow={3: 5.0})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (True, "new tab's field", 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 3, "empty_s": 5.87, "last_s": 5.87})
        # A slow last read: `empty_s` is of the first read with no text, and `last_s` of the last read.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, turns={4: {"typed": 1}}, slow={5: 1.0})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["park_wait"]), (True, {"first": 1, "first_s": 0.77, "reads": 4, "empty_s": 0.97, "last_s": 1.97}))

    def test_a_text_that_the_app_drops_in_the_wait_has_the_word_of_its_end_and_not_the_late_word(self):
        record = self.letters(CHORD, {}, park={"parked": 1}, turns={15: {"dropped_old": 1}})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record.get("letter_also"), record["waits_before_select"]), (False, "dropped after the bound", None, 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 15, "empty_s": 2.07, "last_s": 2.07})
        # The same end with the letter in the field (a text of 2): the field is the app's own work, and the word says so.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 2}, turns={3: {"typed": 1}, 5: {"dropped_old": 1}})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["letter_also"]), (True, "new tab's field", ["dropped after the bound"]))
        self.assertEqual(record["park_wait"], {"first": 2, "first_s": 0.77, "reads": 5, "empty_s": 1.07, "last_s": 1.07})

    def test_a_whole_case_with_2_texts_in_the_park_is_no_pass_while_one_of_them_stays(self):
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 2}, park_end={"typed": 2})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"], record["park_wait"]["first"]), (False, "typed only after the select", 2, 2))
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 2}, turns={3: {"typed": 1}}, park_end={"typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "typed only after the select", 1))
        self.assertEqual(record["park_wait"], {"first": 2, "first_s": 0.77, "reads": 35, "empty_s": None, "last_s": 4.07})
        self.assertEqual(M.verdict("three-key", [record])["waited_first_read"], 1)

    def test_a_text_that_comes_into_the_park_after_an_empty_first_read_gets_a_wait_of_its_own(self):
        # The verdict is of the last read before the tool's acts, not of the first one. A text at that read before
        # the bound came into the park late, and the app's 2 s for it are not over: the case waits again with no
        # other act, then reads the journal again and the park one last time.
        record, after, _ = self.ordered(turns={3: {"parked": 1}, 5: {"typed": 1}})
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (True, "new tab's field", 0))
        self.assertEqual(record["park_wait"], {"first": 0, "first_s": 0.77, "reads": 5, "empty_s": 0.97, "last_s": 0.97})
        self.assertEqual(after, ["pause", "debug.focus", "debug.new_tab", "debug.focus", "debug.journal", "debug.focus", "pause", "debug.focus",
                                 "pause", "debug.focus", "debug.journal", "debug.focus", "focus_pane", "tab.focus"])
        # Such a text that stays to the bound is no pass, with the late word.
        record = self.letters(CHORD, {"t2": "x"}, turns={3: {"parked": 1}}, park_end={"typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "typed only after the select", 1))
        self.assertEqual(record["park_wait"], {"first": 0, "first_s": 0.77, "reads": 36, "empty_s": None, "last_s": 4.07})
        self.assertEqual(M.verdict("three-key", [record])["waited_first_read"], 0)  # the form's count is of the first read only

    def test_a_text_that_comes_into_the_park_after_the_wait_ended_gets_a_second_wait_and_later_seconds_to_an_empty_park(self):
        # A text left at 0.97 s, a second one is there at the last read and leaves at 1.17 s: `empty_s` is of the
        # read from which the park had no text, and the journal's read is the one after the second wait.
        record, after, _ = self.ordered(park={"parked": 1}, turns={4: {"typed": 1}, 5: {"parked": 1}, 7: {"typed": 1}}, journal=[note("page editing=1")])
        self.assertEqual((record["pass"], record["waits_before_select"]), (True, 0))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 7, "empty_s": 1.17, "last_s": 1.17})
        self.assertEqual(after.count("debug.journal"), 2)
        self.assertEqual(after[-4:], ["debug.journal", "debug.focus", "focus_pane", "tab.focus"])
        self.assertEqual(record["journal"]["readiness"]["editing_on"], 1)
        # The second wait is to the same bound: a text that left at 3.57 s, and a second one at the last read that
        # stays, gives reads to 4.07 s and no pass.
        record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, turns={30: {"typed": 1}, 31: {"parked": 1}}, park_end={"typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record["letter_is"], record["waits_before_select"]), (False, "typed only after the select", 1))
        self.assertEqual(record["park_wait"], {"first": 1, "first_s": 0.77, "reads": 36, "empty_s": None, "last_s": 4.07})

    def test_a_forms_line_has_the_seconds_of_a_case_that_is_not_run_in_its_wait(self):
        run = lambda **model: self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, **model)[0].case("three-key", 0)
        stopped = run(blind=(4,))  # no counts at a read of the wait: a text at the first read, and no read with no text
        emptied = run(turns={5: {"typed": 1}}, blind=(6,))  # no counts at the last read, after a read with no text at 1.07 s
        good = run(turns={4: {"typed": 1}})
        self.assertEqual([("pass" in case, case["park_wait"]["first"], case["park_wait"]["empty_s"]) for case in (stopped, emptied, good)],
                         [(False, 1, None), (False, 1, 1.07), (True, 1, 0.97)])
        found = M.verdict("three-key", [stopped, good])
        self.assertEqual((found["verdict"], found["not_run"], found["waited_first_read"], found["emptied_latest_s"]), ("FAIL", 1, 2, 0.97))
        found = M.verdict("three-key", [stopped, emptied, good, good])
        self.assertEqual((found["verdict"], found["not_run"], found["waited_first_read"], found["emptied_latest_s"]), ("FAIL", 2, 4, 1.07))
        found = M.verdict("three-key", [stopped])
        self.assertEqual((found["verdict"], found["waited_first_read"], found["emptied_latest_s"]), ("NOT RUN", 1, None))

    def test_a_read_of_the_wait_with_no_counts_is_not_run_and_the_tool_makes_no_select(self):
        # The reads before the keys and after them had counts. 2: the first read of the park; 3: a read of the wait,
        # or with no text in the park the last read (after the journal's read).
        for park, blind, reads in (({"parked": 1}, 2, 0), ({"parked": 1}, 3, 1), ({"parked": 1}, 9, 7), ({}, 2, 0), ({}, 3, 1)):
            letters, builder, app = self.letters(CHORD, {"t2": "x"}, park=park, blind=(blind,))
            record = letters.case("three-key", 0)
            self.assertEqual(record.get("not_run"), "the read before the select has no counts of the park: no read of a text that waits there", (park, blind))
            self.assertEqual(("pass" in record, record["letter_is"], record.get("park_wait", {}).get("reads", 0)), (False, "not run", reads), (park, blind))
            self.assertEqual((record["park"]["before"] is None, record["park"]["after"] is None, record["park"]["select"]), (False, False, None), (park, blind))
            self.assertEqual([action for action in builder.actions if action[0] == "tab.focus"], [], (park, blind))

    def test_a_read_of_the_wait_that_raises_stops_the_case_with_no_select(self):
        for park, fails in (({"parked": 1}, 4), ({}, 3)):
            letters, builder, app = self.letters(CHORD, {"t2": "x"}, park=park, fails=(fails,))
            record = letters.case("three-key", 0)
            self.assertEqual(record.get("not_run"), "the case stopped: KeyError")  # the class name only
            self.assertNotIn("a text", json.dumps(record))
            self.assertEqual(("pass" in record, record["letter_is"], record["park_wait"]["reads"]), (False, "not run", fails - 2), fails)
            self.assertEqual([action for action in builder.actions if action[0] == "tab.focus"], [], fails)
            self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w"))

    def test_an_exception_of_the_place_reads_keeps_the_late_word_of_a_text_that_waited(self):
        with mock.patch.object(M, "park_change", side_effect=KeyError("a text of the app")):
            record = self.letters(CHORD, {"t2": "x"}, park={"parked": 1}, park_end={"typed": 1})[0].case("three-key", 0)
        self.assertEqual((record["pass"], record.get("not_run"), record["letter_is"], record["places_not_read"]),
                         (False, None, "typed only after the select", ["the places: KeyError"]))


if __name__ == "__main__":
    unittest.main()
