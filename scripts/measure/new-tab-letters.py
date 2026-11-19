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
                   the 3 keys 60 ms after it. `debug.motion` records the spans of the close's move.

THE RULE of a case: no key dropped (`dropped 0` in the hold's log) AND the letter in the first new tab's field; for
from-chat `dropped 1` and no letter in that field. A case whose hold ended before the second New Tab key (the page's
report came first, or the hold kept no key) is a `ready` case: it is counted apart and wants `dropped 0` and the
letter. A form with a second New Tab key and fewer `chord` cases than half of its cases is NOT PROVED.

LIMITS: the cases come after the measure's rows, in the session that the rows left, and a case that would start
after the run's budget (BUDGET_S) is `not_run`. The app is not the active app
in the `one-key` launch form. The time of a key is the app's own play of the sequence. A case does not read which
window was the key window at each key: the hold's log names the responder of a release only.
"""

import re
import time

CMD, SHIFT, T, W, X, NEXT_TAB, PREVIOUS_TAB = 55, 56, 17, 13, 7, 30, 33
GAP_MS = 30.0
SWITCH_WAIT_MS, CLOSE_WAIT_MS = 100.0, 60.0
FORMS = ("reselect", "three-key", "two-key", "from-chat", "switch-next", "switch-previous", "close-move")
WANT_DROPPED = {"from-chat": 1}
NO_CHORD = ("two-key",)
BUDGET_S = 900.0  # of all cases of a run: a case that would start later is `not_run`
SETTLE_S = 0.7  # after a sequence: the 3 keys take 70 ms, and the hold's log has each note at once
DROPPED = re.compile(r"dropped (\d+) key")
NOT_PROVED = "NOT PROVED: too few chord cases"


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
    has = text is not None and "x" in text
    return {"chord": chord_case, "dropped": dropped, "want_dropped": want, "letter_in_field": has if text is not None else None,
            "pass": dropped == want and text is not None and has == (want == 0)}


def verdict(form, cases):
    """A form's counts and its word: PASS, FAIL or NOT PROVED."""
    ran = [case for case in cases if "pass" in case]
    chords = [case for case in ran if case["chord"]]
    counts = {"cases": len(cases), "ran": len(ran), "not_run": len(cases) - len(ran), "chord": len(chords),
              "chord_pass": sum(case["pass"] for case in chords), "ready": len(ran) - len(chords),
              "ready_pass": sum(case["pass"] for case in ran if not case["chord"]),
              "dropped": sorted(case["dropped"] for case in ran)}
    if not ran:
        word = "NOT RUN"
    elif form not in NO_CHORD and len(chords) * 2 < len(cases):
        word = NOT_PROVED
    else:
        word = "PASS" if all(case["pass"] for case in ran) and len(ran) == len(cases) else "FAIL"
    return {"form": form, "verdict": word, **counts}


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

    def select(self, tab):
        self.builder.action("tab.focus", target=f"tab:{tab}")
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
            self.select(first)
            self.select(second)
        elif form == "from-chat":
            fallbacks, before = self.builder.chat_fallbacks, set(self.ids(workspace, pane))
            self.builder.add_tab(workspace, pane, "chat")
            chat = next((tab for tab in self.ids(workspace, pane) if tab not in before), None)
            if self.builder.chat_fallbacks != fallbacks or not chat:
                raise NotRun("the app opened no agent chat")
            self.select(chat)
            self.rpc("debug.agent_pane", {"action": "focus_composer", "pane": pane})
            focused = self.wait(lambda: (self.rpc("debug.agent_pane", {"action": "composer_focused", "pane": pane}) or {}).get("focused"), 20, 0.1)
            if not focused:
                raise NotRun("the chat's field did not get the keyboard")
        elif form in ("switch-next", "switch-previous"):
            for tab in (first, None):  # a letter in each of the 2 tabs; the record says what each field then had
                tab or self.page_tab(workspace, pane)
                self.keys(pane, letter())
                self.setup_fields.append(self.field().get("text"))
            if form == "switch-next":
                self.select(first)
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
            if form == "close-move":
                self.rpc("debug.motion", {"action": "start"})
            sent = self.keys(source, steps)
            notes = new_notes(log, self.notes())
            if form == "close-move":
                motion = self.rpc("debug.motion", {"action": "stop"}) or {}
                record["motion"] = {"pane_animations": motion.get("pane_animations"), "reduce_motion": motion.get("reduce_motion"),
                                    "spans": (motion.get("spans") or [])[:12]}
                record["panes_after"] = len(self.builder.panes(self.builder.workspace(workspace)))
            made = [tab for tab in self.ids(workspace, target) if tab not in had]
            after = (self.rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or []
            # The app's list of openings is a ring: the last ones are the case's (one for each New Tab key of the 3 keys).
            record.update({"key_window": sent.get("key_window"), "notes": notes, "tabs_made": len(made),
                           "openings": [{key: opening.get(key) for key in ("spare", "idle")}
                                        for opening in after[-(1 if form in NO_CHORD else 2):]]})
            if not made:
                raise NotRun("the keys made no tab in the pane")
            self.builder.focus_pane(target)
            self.select(made[0])
            if made[0] not in [tab.get("id") for tab in self.builder.tabs(workspace, target) if tab.get("selected")]:
                raise NotRun(f"the pane does not show the first new tab {made[0]} after its select")
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

    def run(self, count, forms=FORMS, say=print, budget_s=BUDGET_S, now=time.monotonic):
        """`count` cases of each form, form after form: {"forms": [each form's verdict], "cases": [each record]}.
        A case that would start after `budget_s` seconds is `not_run`: the cases cannot use up the step's time."""
        report, end = {"gap_ms": GAP_MS, "budget_s": budget_s, "forms": [], "cases": []}, now() + budget_s
        late = f"the budget of the letter cases ({budget_s:.0f} s) ended before this case"
        for form in forms:
            cases = [self.case(form, index) if now() < end else {"form": form, "case": index, "not_run": late} for index in range(count)]
            for record in cases:
                say("HELD-NEW-TAB-LETTER-CASE " + repr(record))
            report["cases"] += cases
            report["forms"].append(verdict(form, cases))
            say("HELD-NEW-TAB-LETTER-FORM " + repr(report["forms"][-1]))
        return report
