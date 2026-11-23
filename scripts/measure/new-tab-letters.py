#!/usr/bin/env python3
"""The letter cases of the held New Tab measure (`held-new-tab.py --letter-cases N`): a letter that a person types
directly after a New Tab key in the real app, with the keyboard in a page's window.

Each case is in a workspace of its own and has ONE key sequence of the app (`debug.key` with `key_window: page`):
the app makes the Chromium page window of the case's pane its key window with no activation and posts real key
events to its own queue. So each New Tab key of a case is the person's key. (An opening by a script has no keyboard
owner: the key hold drops no key for it, and a case with such an opening proves nothing.) After the sequence a case
reads the key hold's log (`debug.focus`, `new_tab_key_log`), the record of the openings (`debug.new_tab`, `state`),
and the text of the first new tab's field (`debug.new_tab`, `field`) after a select of that tab (`tab.focus`).

THE 3 KEYS: a New Tab key, the letter x 30 ms later, a second New Tab key 30 ms after the letter. The second New Tab
key is a key with Command while the hold has the letter: the hold ends with no field ready (`release: chord`).

FORMS
  reselect         the pane shows New Tab tab A; a New Tab key (tab B); a select of A, a select of B; the 3 keys.
  three-key        the pane shows an untouched New Tab tab; the 3 keys.
  two-key          the same with no second New Tab key: a guard (the hold ends by the page's report).
  from-chat        the pane shows an agent chat with the keyboard in its field, and has a hidden untouched New Tab
                   tab; the 3 keys. The person left the chat, so the hold keeps its owner: WANT `dropped 1`.
  switch-next      2 New Tab tabs that each got a letter; a Next Tab key, and the 3 keys 100 ms after it.
  switch-previous  the same with a Previous Tab key.
  close-move       2 panes; the second has one New Tab tab and the keyboard; a Close Tab key (the pane closes), and
                   the 3 keys 60 ms after it. The app's notes of `debug.motion` say if the close moved its panes
                   (`layout.commit: close moves N panes`) or showed in one frame; the record keeps them.

THE RULE of a case: no key dropped (`dropped 0` in the hold's log) AND the first new tab's field is the letter; for
from-chat `dropped 1` and an empty field. A case whose hold ended before the second New Tab key (the page's
report came first, or the hold kept no key) is a `ready` case: it is counted apart and wants `dropped 0` and the
letter. A form with a second New Tab key and fewer `chord` cases than half of its cases is NOT PROVED. A case of
close-move whose close did not move its panes (Reduce Motion, pane animations off, a close in one frame) is counted
apart (`no_move`), and the form with fewer cases in a move than half of its cases is NOT PROVED: with no move the
form is the plain close of a pane. A case with no note of a hold's start in the log is `not_run`: no read is not
`dropped 0`. A switch case whose setup did not put the letter in each of its 2 fields is `not_run`. A select is
done when the app names its tab as the tab that the pane shows (`Letters.shown`); a case with a select that the
pane does not show in SELECT_S is `not_run`, and its record has the tab that the pane shows and the app's refusal.

LIMITS: the cases come after the measure's rows, in the session that the rows left, and a case that would start
after the run's budget (BUDGET_S) is `not_run`. The app is not the active app
in the `one-key` launch form. The time of a key is the app's own play of the sequence. A case does not read which
window was the key window at each key: the hold's log names the responder of a release only. close-move does not
prove that the 3 keys came in the time of the move: the record has the move's note with its time, and the tool
compares no times. The record's `openings` are the last ones of the app's list: when a key of the case made no
opening, an older opening is in the record (`tabs_made` says how many tabs the keys made).
"""

import json
import re
import time

CMD, SHIFT, T, W, X, NEXT_TAB, PREVIOUS_TAB = 55, 56, 17, 13, 7, 30, 33
GAP_MS = 30.0
SWITCH_WAIT_MS, CLOSE_WAIT_MS = 100.0, 60.0
# The order of a run: the budget cuts the last forms, so the guard is last.
FORMS = ("reselect", "close-move", "from-chat", "three-key", "switch-next", "switch-previous", "two-key")
WANT_DROPPED = {"from-chat": 1}
NO_CHORD = ("two-key",)
MOVE_FORMS = ("close-move",)  # a case of these proves its form only when the app's notes say that the close moved
SWITCH_FORMS = ("switch-next", "switch-previous")
LETTER = "x"  # what the key X puts in a field
BUDGET_S = 900.0  # of all cases of a run: a case that would start later is `not_run`
SETTLE_S = 0.7  # after a sequence: the 3 keys take 70 ms, and the hold's log has each note at once
SELECT_S = 5.0  # for the app's word that a pane shows the tab of a select; after it the case is `not_run`
DROPPED = re.compile(r"dropped (\d+) key")
COMMIT, MOVES = "layout.commit", re.compile(r"layout\.commit: close moves \d+ panes")
OPENING_KEYS = ("spare", "idle", "cross_window", "refit")  # an app gives a part of them: the record has what it gave
NOT_PROVED = "NOT PROVED: too few chord cases"
NO_MOVE = "NOT PROVED: too few cases in a close's move"


def chord(code, after_ms=0.0, shift=False):
    """A key with Command (and Shift) as steps; the first step comes `after_ms` after the step before it. The key
    goes down 2 ms after Command (3 ms with Shift), and the steps take 10 ms (12 ms with Shift)."""
    steps = [{"key_code": CMD, "down": True, "after_ms": after_ms}]
    steps += [{"key_code": SHIFT, "down": True, "after_ms": 1}] if shift else []
    steps += [{"key_code": code, "down": True, "after_ms": 2}, {"key_code": code, "down": False, "after_ms": 6}]
    steps += [{"key_code": SHIFT, "down": False, "after_ms": 1}] if shift else []
    return steps + [{"key_code": CMD, "down": False, "after_ms": 2}]


def letter(after_ms=0.0):
    return [{"key_code": X, "down": True, "after_ms": after_ms}, {"key_code": X, "down": False, "after_ms": 6}]


def three_keys(wait_ms=0.0, second=True):
    """The 3 keys as steps (2 keys with `second` False): each key-down is GAP_MS after the key-down before it."""
    return chord(T, wait_ms) + letter(GAP_MS - 8) + (chord(T, GAP_MS - 8) if second else [])


def new_notes(before, after):
    """The notes of the read `after` that came after the read `before`. The log is a ring: its oldest notes go."""
    for count in range(len(after) + 1):
        if (before + after[len(after) - count:])[-len(after):] == after:
            return after[len(after) - count:]
    return list(after)


def judge(form, notes, text):
    """One case's verdict from the hold's notes of the case and the text of the first new tab's field (None: no
    read). `chord`: the hold ended at the second New Tab key with no field ready before it."""
    dropped = sum(int(found.group(1)) for found in map(DROPPED.search, notes) if found)
    release = next((index for index, note in enumerate(notes) if "release: chord, keys" in note), None)
    ready = next((index for index, note in enumerate(notes) if "ready match" in note), None)
    chord_case = release is not None and (ready is None or ready > release)
    want = WANT_DROPPED.get(form, 0) if chord_case else 0
    # The field of a new tab is the letter and no more (a letter that came 2 times is no pass), or empty for a drop.
    return {"chord": chord_case, "dropped": dropped, "want_dropped": want, "letter_in_field": None if text is None else LETTER in text,
            "pass": dropped == want and text == ("" if want else LETTER)}


def moved(notes):
    """Did the close of a case move its panes? From the app's motion notes of the case (`{"text": ...}` each)."""
    return any(MOVES.search(str(note.get("text"))) for note in notes)


def verdict(form, cases):
    """A form's counts and its word: PASS, FAIL, NOT PROVED or NOT RUN."""
    ran = [case for case in cases if "pass" in case]
    chords = [case for case in ran if case["chord"]]
    moves = [case for case in ran if case.get("moved")]
    counts = {"cases": len(cases), "ran": len(ran), "not_run": len(cases) - len(ran), "chord": len(chords),
              "chord_pass": sum(case["pass"] for case in chords), "ready": len(ran) - len(chords),
              "ready_pass": sum(case["pass"] for case in ran if not case["chord"]),
              "dropped": sorted(case["dropped"] for case in ran),
              **({"move": len(moves), "no_move": len(ran) - len(moves)} if form in MOVE_FORMS else {})}
    if not ran:
        word = "NOT RUN"
    elif form not in NO_CHORD and len(chords) * 2 < len(cases):
        word = NOT_PROVED
    elif not all(case["pass"] for case in ran) or len(ran) != len(cases):
        word = "FAIL"
    else:
        word = NO_MOVE if form in MOVE_FORMS and len(moves) * 2 < len(cases) else "PASS"
    return {"form": form, "verdict": word, **counts}


def line(kind, record):
    """One line of the tool's output: JSON after its name, as each other line of the measure."""
    return f"HELD-NEW-TAB-LETTER-{kind} " + json.dumps(record, default=str)


def out(text):
    print(text, flush=True)


class NotRun(RuntimeError):
    """A case whose setup did not make the state that the form needs."""


class Letters:
    """The cases against one app: `builder` is the session helper (perf-stress-session.py `Stress`), `rpc` the
    app's socket call, `wait` the helper's wait (predicate, seconds, step)."""

    def __init__(self, builder, rpc, wait, pause=time.sleep):
        self.builder, self.rpc, self.wait, self.pause, self.setup_fields = builder, rpc, wait, pause, []

    def notes(self):
        return list((self.rpc("debug.focus") or {}).get("new_tab_key_log") or [])

    def field(self):
        reply = self.rpc("debug.new_tab", {"action": "field"})
        return reply if isinstance(reply, dict) else {}

    def ids(self, workspace, pane):
        return [tab.get("id") for tab in self.builder.settled_tabs(workspace, pane, seconds=10)]

    def shown(self, workspace, pane):
        """The tab that `pane` shows, by the app's word, or None. The snapshot names it in the pane's `selected_tab`
        (a tab of the daemon has no key `selected` there; an app-only page tab has one). When the snapshot names
        none, the focus model's word on the pane (`debug.focus`), as the measure's own read of a pane does."""
        found = next((part for part in self.builder.panes(self.builder.workspace(workspace)) if part.get("id") == pane), None) or {}
        store = found.get("selected_tab") or next((tab.get("id") for tab in found.get("tabs") or [] if tab.get("selected")), None)
        return store or next((part.get("selected") for window in (self.rpc("debug.focus") or {}).get("windows") or []
                              for part in window.get("topology") or [] if part.get("pane") == pane), None)

    def select(self, tab, workspace, pane):
        """`pane` shows `tab`: the action, then a wait for the app's word that the pane shows it (SELECT_S at most)."""
        reply = self.builder.action("tab.focus", target=f"tab:{tab}")
        if not self.wait(lambda: self.shown(workspace, pane) == tab, SELECT_S, 0.1):
            shown, said = self.shown(workspace, pane), reply.get("error") if isinstance(reply, dict) else None
            raise NotRun(f"the pane shows {f'the tab {shown}' if shown else 'no tab that the app names'}, not the tab {tab}, "
                         f"after its select" + (f": the app said: {str(said)[:160]}" if said else ""))
        self.pause(0.4)  # test script: the pane's paint hold is 500 ms at most, and the next act is a read or a key

    def keys(self, pane, steps):
        sent = self.rpc("debug.key", {"sequence": steps, "key_window": "page", "pane": pane}) or {}
        if not isinstance(sent, dict) or sent.get("error"):
            raise NotRun(f"the app refused the sequence: {str(sent.get('error') if isinstance(sent, dict) else sent)[:160]}")
        self.pause(sum(step.get("after_ms") or 0 for step in steps) / 1000 + SETTLE_S)
        return sent

    def page_tab(self, workspace, pane):
        """One New Tab tab that a script opens in `pane` and that the pane shows, with its field ready."""
        before = set(self.ids(workspace, pane))
        self.builder.action("newTab.page", target=f"pane:{pane}")
        made = self.wait(lambda: next((tab for tab in self.ids(workspace, pane) if tab not in before), None), 20, 0.1)
        if not made or not self.wait(lambda: self.field().get("text") == "", 20, 0.1):
            raise NotRun(f"no New Tab tab with a ready field in pane {pane} (tab {made})")
        return made

    def setup(self, form, workspace, pane):
        """The state of `form`: (the pane of the sequence, the pane of the new tabs, the steps)."""
        first = self.page_tab(workspace, pane)
        if form == "reselect":
            before = set(self.ids(workspace, pane))
            self.keys(pane, chord(T))
            second = next((tab for tab in self.ids(workspace, pane) if tab not in before), None)
            if not second or not self.wait(lambda: self.field().get("text") == "", 20, 0.1):
                raise NotRun("the New Tab key of the setup made no tab with a ready field")
            self.select(first, workspace, pane)
            self.select(second, workspace, pane)
        elif form == "from-chat":
            fallbacks, before = self.builder.chat_fallbacks, set(self.ids(workspace, pane))
            self.builder.add_tab(workspace, pane, "chat")
            chat = next((tab for tab in self.ids(workspace, pane) if tab not in before), None)
            if self.builder.chat_fallbacks != fallbacks or not chat:
                raise NotRun("the app opened no agent chat")
            self.select(chat, workspace, pane)
            self.rpc("debug.agent_pane", {"action": "focus_composer", "pane": pane})
            focused = self.wait(lambda: (self.rpc("debug.agent_pane", {"action": "composer_focused", "pane": pane}) or {}).get("focused"), 20, 0.1)
            if not focused:
                raise NotRun("the chat's field did not get the keyboard")
        elif form in SWITCH_FORMS:
            for tab in (first, None):  # a letter in each of the 2 tabs; the record says what each field then had
                tab or self.page_tab(workspace, pane)
                self.keys(pane, letter())
                self.setup_fields.append(self.field().get("text"))
            if self.setup_fields != [LETTER, LETTER]:
                raise NotRun(f"a letter of the setup did not get to its field: the 2 fields have {self.setup_fields}")
            if form == "switch-next":
                self.select(first, workspace, pane)
            return pane, pane, chord(NEXT_TAB if form == "switch-next" else PREVIOUS_TAB, shift=True) + three_keys(SWITCH_WAIT_MS)
        elif form == "close-move":
            other = self.builder.split(workspace, pane, "splitRight")
            if not other:
                raise NotRun("the split made no pane")
            came = self.ids(workspace, other)
            self.builder.focus_pane(other)
            self.page_tab(workspace, other)
            for tab in came:
                self.builder.action("closeTab", target=f"tab:{tab}", focus=False)
            if not self.wait(lambda: len(self.builder.tabs(workspace, other)) == 1, 10, 0.1):
                raise NotRun("the second pane did not get to one tab")
            self.builder.focus_pane(other)
            return other, pane, chord(W) + three_keys(CLOSE_WAIT_MS)
        return pane, pane, three_keys(second=form not in NO_CHORD)

    def case(self, form, index):
        """One case in a workspace of its own, which is closed after it: the case's record."""
        record, workspace, self.setup_fields = {"form": form, "case": index}, self.builder.new_workspace(), []
        try:
            if not workspace:
                raise NotRun("no new workspace")
            self.builder.show(workspace)
            pane = self.builder.panes(self.builder.workspace(workspace))[0]["id"]
            source, target, steps = self.setup(form, workspace, pane)
            had, log = set(self.ids(workspace, target)), self.notes()
            if form in MOVE_FORMS:
                self.rpc("debug.motion", {"action": "start"})
            sent = self.keys(source, steps)
            notes = new_notes(log, self.notes())
            if form in MOVE_FORMS:
                motion = self.rpc("debug.motion", {"action": "stop"}) or {}
                # The app's own word for the close: `layout.commit: close moves N panes ...` or `... in one frame (...)`.
                commits = [note for note in motion.get("notes") or [] if isinstance(note, dict) and COMMIT in str(note.get("text"))]
                record["motion"] = {"pane_animations": motion.get("pane_animations"), "reduce_motion": motion.get("reduce_motion"),
                                    "spans": (motion.get("spans") or [])[:12], "notes": commits[:12]}
                record["moved"] = moved(commits)
                record["panes_after"] = len(self.builder.panes(self.builder.workspace(workspace)))
            made = [tab for tab in self.ids(workspace, target) if tab not in had]
            after = (self.rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or []
            # The app's list of openings is a ring: the last ones are the case's (one for each New Tab key of the 3 keys).
            record.update({"key_window": sent.get("key_window"), "notes": notes, "tabs_made": len(made),
                           "openings": [{key: opening[key] for key in OPENING_KEYS if key in opening}
                                        for opening in after[-(1 if form in NO_CHORD else 2):] if isinstance(opening, dict)]})
            if not any(note.startswith("begin ") for note in notes):
                raise NotRun("the hold's log has no note of a hold's start for the case's keys: no read of what the hold did")
            if not made:
                raise NotRun("the keys made no tab in the pane")
            self.builder.focus_pane(target)
            self.select(made[0], workspace, target)
            text = self.wait(lambda: self.field().get("text"), 5, 0.1) or self.field().get("text")
            record.update({"field": text, **judge(form, notes, text)})
        except NotRun as error:
            record["not_run"] = str(error)
        except Exception as error:  # noqa: BLE001  one case that stopped must not lose the other cases
            record["not_run"] = f"the case stopped: {error!r}"
        finally:
            if self.setup_fields:
                record["setup_fields"] = self.setup_fields
            if workspace:
                try:
                    self.builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
                except Exception as error:  # noqa: BLE001
                    record["workspace_not_closed"] = repr(error)
        return record

    def run(self, count, forms=FORMS, say=out, budget_s=BUDGET_S, now=time.monotonic):
        """`count` cases of each form, form after form: {"forms": [each form's verdict], "cases": [each record]}.
        A case that would start after `budget_s` seconds is `not_run`: the cases cannot use up the step's time."""
        report, end = {"gap_ms": GAP_MS, "budget_s": budget_s, "forms": [], "cases": []}, now() + budget_s
        late = f"the budget of the letter cases ({budget_s:.0f} s) ended before this case"
        for form in forms:
            cases = [self.case(form, index) if now() < end else {"form": form, "case": index, "not_run": late} for index in range(count)]
            for record in cases:
                say(line("CASE", record))
            report["cases"] += cases
            report["forms"].append(verdict(form, cases))
            say(line("FORM", report["forms"][-1]))
        return report


def ran_none(report):
    """Why a run's letter cases proved nothing, or None: the report of `Letters.run`, or the words of a run that
    ended before them. No case ran when the report has no form, or when each form's word is NOT RUN."""
    forms = report.get("forms") if isinstance(report, dict) else None
    if not forms:
        return str(report.get("not_run") or "the report has no form") if isinstance(report, dict) else "no report"
    return "each form is NOT RUN" if all(isinstance(form, dict) and form.get("verdict") == "NOT RUN" for form in forms) else None
