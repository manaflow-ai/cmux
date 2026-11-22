#!/usr/bin/env python3
"""The letter cases of the held New Tab measure (`held-new-tab.py --letter-cases N`): a letter that a person types
directly after a New Tab key in the real app, with the keyboard in a page's window.

Each case is in a workspace of its own and has ONE key sequence of the app (`debug.key` with `key_window: page`):
the app makes the Chromium page window of the case's pane its key window with no activation and posts real key
events to its own queue. So each New Tab key of a case is the person's key. (An opening by a script has no keyboard
owner: the key hold drops no key for it, and a case with such an opening proves nothing.) After the sequence a case
reads the key hold's log (`debug.focus`, `new_tab_key_log`), the record of the openings (`debug.new_tab`, `state`),
and the text of the first new tab's field (`debug.new_tab`, `field`) after a select of that tab (`tab.focus`).

WHERE THE LETTER IS. After those reads (their time is as it was) a case reads the places that a letter can go to:
the second new tab's field, the field of each tab that the pane showed before the keys (`Letters.before`; for an
agent chat its composer, `debug.agent_pane` `query`), and the counts of the app's park for typed text
(`debug.focus`, `parked_typing`) before the keys, after them, at the last read before the tool's own acts and at
the case's end. The record's `letter_is` is ONE
word of WHERE (12 words), the first that is true, in this order: `typed only after the select` (the first new tab's
field has the letter, and a text was in the park at the last read before the tool's acts: see THE SELECT), `new tab's field`
(the first new tab), `second new
tab's field`, `tab before` (such a field has one letter more than before the keys; with no read before the keys
this is not said), `refused by the field`, `dropped after the bound`, `page gone` (the park's counts
`dropped_refused`, `dropped_old`, `dropped_page_gone` went up in the case), `parked` (a text came into the park and
did not leave it); then, when none of these 8 is true: `not run` (the case did not run), `dropped by the hold`
(the hold's log says `dropped N`, N above 0), `a place not read` (a place gave no answer), `nowhere read`. So
`nowhere read` is said only for a case that ran, with no dropped key and an answer of each place. When 2 or more
of the first 8 words are true, the record's `letter_also` has the other words. A place that gave no answer is in
the record's `places_not_read` as `place: why`; the place is the record's key (`field`, `second_new_tab_field`,
`tabs_before[N]`, `park.before`, `park.end`), and why is: `no dict`, `error`, `no element`, `no text` (a reply
that is no dict, has an `error`, found no element, has no text), `no parked_typing` (a `debug.focus` reply with no
counts), the app's refusal of a select, or the class name of an exception. A form's line counts its cases with
such a place (`places_not_read`). No place of that list changes a verdict or makes a case `not_run`. (The reads
of the park before the tool's acts, `park.select`, are not of that list: they are the rule's own reads, and a case
with no counts there is `not_run`, see THE SELECT.) The record's `app`
has the app's own word on its active state and the class of its key window, before and after the keys. A record
has no text of a field but the letter: `seen` gives a word for each other text.

THE SELECT. The tool reads the first new tab's field after its own select of that tab, and the select gives the
tab the keyboard: the app then types a text that waits in its park for that tab's page. A person makes no such
select in the 2 s that the park keeps a text. So a case reads the park's counts again before its own acts on the
first new tab (the focus of the tab's pane, then the select). With one text or more in the park at that read
(each text that came less each that left: such a text waits or is on its way into its page; the counts do not say
which text) the case makes NO other act: it reads the park again each WAIT_STEP_S (0.1 s), to the first read with
no text there or to the first read WAIT_S (4 s) and more after the sequence's last key. The park keeps a text
for 2 s from the app's own dispatch of the key that parks it (the app can dispatch a key later than the key's time
in the sequence), and at each read the app drops a text that only waited that long. So the app's own clock ends
the wait (the app types the text by itself or drops it), and only a text that stays on its way into its page gets
to the 4 s. Then the case reads the app's input journal (`debug.journal`), and then the park ONE more time. With a
text at that read before the 4 s (a text that came into the park late) the case waits again in the same way, and
then reads the journal and the park again. The last read of the park is the tool's LAST call before its own acts,
and the record's `park.select` and `waits_before_select` (the count of the texts in the park) are of it. With one text or
more at that last read the case is NO PASS, also when the field then has the letter: `letter_is` is `typed only
after the select` (and `letter_also` has `new tab's field`), or the word of the letter's other place. With no text
at that last read the verdict is by the places as before: the letter in the first new tab's field is then the
app's own work, and the case can pass. The record's `park_wait` has `first` (the count at the first read),
`first_s`, `empty_s` (to the first read with no text in the park that has no read with a text after it; None: the
last read has a text) and `last_s`, each in
seconds from the app's reply to the call of the keys to that read's end, and `reads` (how many reads of the park).
`holds_before_select` is the count of the windows with an open New Tab key hold at the last read (None: the reply
has no such list): a count only, it changes no verdict. A form's line
counts its cases with a text at the last read (`waited_before_select`) and at the first read (`waited_first_read`),
and has the most seconds to an empty park of the cases that waited (`emptied_latest_s`). A case with no counts of
the park at one of these reads, or with a count below 0, is `not_run`, and the tool makes no select: no read is not
`no text waits`. The record's `waits_before_keys` is the count before the keys: with a text there the case is
`not_run` and sends no key (a text that waits later can be that older one). From the journal's entries after the
last one before the keys the record
has `journal`: `readiness`, the counts of the notes of the pages' input readiness (`focus`: a focus message of a
page's script; `editing_on`, `editing_off`: the script's word that an editable element has the focus or lost it;
`key`: a key that came to a page's document; `wait`, `wait_end`: a wait for a command's field); `first_new_tab`,
how many times the app gave and took the page focus of the first new tab, and its engine words in their order (a
word that the tool does not know is `other`); `page_entries`, how many entries name a page's focus for each tab
that has one, and for the first new tab; `whole` (False: the read was cut) and `entries`. The record's `engine` is
the last engine word (None: no entry names the tab). The app writes no such entry for a New Tab page in a WebKit
view (only for a browser tab in a view and for a page in a Chromium child window): there `engine` None and the 2
counts of 0 are not facts of the app. The journal changes no verdict: with no read, and with an entry of a form
that the tool does not know, the record has `journal.not_read` with the why.

THE 3 KEYS: a New Tab key, the letter x 30 ms later, a second New Tab key 30 ms after the letter. The second New Tab
key is a key with Command while the hold has the letter: the hold ends with no field ready (`release: chord`).

FORMS
  reselect         the pane shows New Tab tab A; a New Tab key (tab B); a select of A, a select of B; the 3 keys.
  three-key        the pane shows an untouched New Tab tab; the 3 keys.
  two-key          the same with no second New Tab key: a guard (the hold ends by the page's report).
  from-chat        the pane shows an agent chat with the keyboard in its field, and has a hidden untouched New Tab
                   tab; the 3 keys. The letter comes after the New Tab key: it is the new tab's, as in each form.
  switch-next      2 New Tab tabs that each got a letter; a Next Tab key, and the 3 keys 100 ms after it.
  switch-previous  the same with a Previous Tab key.
  close-move       2 panes; the second has one New Tab tab and the keyboard; a Close Tab key (the pane closes), and
                   the 3 keys 60 ms after it. The app's notes of `debug.motion` say if the close moved its panes
                   (`layout.commit: close moves N panes`) or showed in one frame; the record keeps them.

THE RULE of a case, in each form: no key dropped (`dropped 0` in the hold's log) AND the first new tab's field is the
letter AND no text was in the park at the last read before the tool's acts (THE SELECT). (To 22 November 2026 from-chat had a rule of its own, `dropped 1` and an empty field: the chat had the
keyboard at the opening, so the hold was to drop the letter. The app gives a letter to the new tab's type-ahead
before it asks the hold's drop rule, so the hold drops no key there; and the letter came after the New Tab key.)
A case whose hold ended before the second New Tab key (the page's report came first, or the hold kept no key) is a
`ready` case: it is counted apart. A form with a second New Tab key and fewer `chord` cases than half of its cases
is NOT PROVED. A case of close-move whose close did not move its panes (Reduce Motion, pane animations off, a close
in one frame) is counted apart (`no_move`), and the form with fewer cases in a move than half of its cases is NOT
PROVED: with no move the form is the plain close of a pane. A case with no note of a hold's start in the log is
`not_run`: no read is not `dropped 0`. A switch case whose setup did not put the letter in each of its 2 fields is
`not_run`. A select is
done when the app names its tab as the tab that the pane shows (`Letters.shown`); a case with a select that the
pane does not show in SELECT_S is `not_run`, and its record has the tab that the pane shows and the app's refusal.

LIMITS: the cases come after the measure's rows, in the session that the rows left, and a case that would start
after the run's budget (BUDGET_S) is `not_run`. The key call does not activate the app, and it does not say if the
app is the active app: the record's `app` has the app's word. The keys do not come from the HID tap or the window
server. The time of a key is the app's own play of the sequence. A case does not read which window was the key
window at each key (the record's `app` has its class before and after the keys only): the hold's log names the
responder of a release only. The time of the reads of the places: when the first new tab's field is empty, the verdict's
read waits its full 5 s for a text, so the reads of the places come 5.7 s and more after the keys (0.7 s and more
only when that field has a text). The park keeps a text for 2 s at most and drops an older one at each
`debug.focus` read. So `parked` is almost never said (only for a text that is on its way for more than 5 s): a
parked text that got to no field is `dropped after the bound`, and the tool's own read at the case's end can be
the read that makes that count. The first read of the park before the tool's acts comes 0.7 s and more after the
keys. The last one comes directly after the first read with no text (a text that leaves the park 1.0 s after the
keys gives a last read at about 1.0 s), and 4 s and more after the keys only for a text that stays to the bound.
Each read of the wait is a `debug.focus` read too, and can be the read that drops a text older than 2 s (the app
does the same drop before it types). So after the wait `typed only after the select` is almost never said (only
for a text that stays on its way into its page for the 4 s): a text that the app does not type by itself is
`dropped after the bound` with no text at the last read, and the count of such cases is the form's
`waited_first_read` less those of them that pass. A case
with a text in the park takes up to 3.3 s more. A case with no text at the first read and a text at a later one is
not in `waited_first_read` (its `park_wait.reads` is above 2). A text that is on its way into its page at the last read counts
as a text in the park (no pass), and a text that the app types between the last read and the select (the focus
call of the pane) is said as typed after the select. The seconds of `park_wait` are of the tool's clock at each
reply, not of the app's. The tool does not read the type-ahead queue of a key hold.
The journal's readiness notes name no page: their counts are of each page of the app in that time, not of the
first new tab's page only. The journal has no note for a page's plain ready message: `editing_on` is the note
that the page's script sends in the same call as a document's first ready message, and at each later focus of an
editable element. The engine word is the app's word at a change of that page's focus (`webkit`, `chromium`, or a
word for a Chromium page's window that became the key window); the tool does not read that the journal names a
page by the tab's id. close-move does not
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
# Where a case's letter is (`letter_is`): the first word that is true, in this order. The first 8: a read found the
# letter (the first one: in the first new tab's field, with a text in the park before the select). The last 4, in
# their order: the case did not run; the hold dropped a key; a place gave no answer; none.
WHERE = ("typed only after the select", "new tab's field", "second new tab's field", "tab before", "refused by the field",
         "dropped after the bound", "page gone", "parked", "not run", "dropped by the hold", "a place not read", "nowhere read")
LATE, FIELD, SECOND, BEFORE = WHERE[:4]
NO_RUN, BY_HOLD, UNREAD, NOWHERE = WHERE[8:]
NO_COUNTS = "the read before the select has no counts of the park: no read of a text that waits there"
BELOW = "the park's counts give {} texts, a count below 0: no read of a text that waits there"
OLDER = "{} texts were in the park before the case's keys: a text that waits later can be an older one"
# After a case's keys. The park keeps a text for 2 s (TypingPark.swift `limit`) from the app's own dispatch of the
# key, which can be later than the key's time in the sequence: the app's drop of such a text at a read ends the wait
# by the app's clock, and only a text that stays on its way into its page gets to this bound.
WAIT_S = 4.0
WAIT_STEP_S = 0.1  # between 2 reads of the park while a text waits there
JOURNAL_LAST = 600  # the entries of the journal's read before the select: a case's keys and pages write far fewer
ENGINES = ("webkit", "chromium", "chromium-key", "chromium-unchosen-key")  # the app's words (FocusEffectApplier.swift)
# The notes of a page's input readiness in the journal (PageInputReadiness.swift `trace`), by the record's name.
NOTES = (("focus", re.compile(r"^page (?:.* )?epoch=\d+(?: |$)")), ("editing_on", re.compile(r"^page (?:.* )?editing=(?:1|true)(?: |$)")),
         ("editing_off", re.compile(r"^page (?:.* )?editing=(?:0|false)(?: |$)")), ("key", re.compile(r"^page (?:.* )?keyTarget=")),
         ("wait", re.compile(r"^wait (?!end(?: |$))")), ("wait_end", re.compile(r"^wait end(?: |$)")))
# The park's counts in `debug.focus` (TypingPark.swift), and the word of each count of a text that left with no field.
PARK = ("parked", "typed", "dropped_old", "dropped_page_gone", "dropped_refused", "dropped_returns")
LEFT = (("dropped_refused", "refused by the field"), ("dropped_old", "dropped after the bound"), ("dropped_page_gone", "page gone"))
COMPOSER = '.acpmux-composer [contenteditable="true"]'  # the field of an agent chat (DebugAgentPane.swift)


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


def judge(notes, text, waits=0):
    """One case's verdict from the hold's notes of the case, the text of the first new tab's field (None: no read)
    and `waits`, the texts in the park at the read before the select; each form has the one rule. `chord`: the hold
    ended at the second New Tab key with no field ready before it. A note before the case's first `begin` is not of
    the case's hold (a page of the setup that reported after
    the read of the log): it makes no `ready` case. The count of dropped keys is of each note."""
    dropped = sum(int(found.group(1)) for found in map(DROPPED.search, notes) if found)
    own = notes[next((index for index, note in enumerate(notes) if note.startswith("begin ")), 0):]
    release = next((index for index, note in enumerate(own) if "release: chord, keys" in note), None)
    ready = next((index for index, note in enumerate(own) if "ready match" in note), None)
    chord_case = release is not None and (ready is None or ready > release)
    # The field of a new tab is the letter and no more (a letter that came 2 times is no pass), and no text was in
    # the park before the tool's select: the select gives the tab the keyboard, and a parked text is typed then.
    return {"chord": chord_case, "dropped": dropped, "letter_in_field": None if text is None else LETTER in text,
            "pass": dropped == 0 and text == LETTER and not waits}


def seen(text):
    """What a record says of a field's text: None (no read), "" (an empty field), the letter, or a word for each
    other text. No other text of a field goes into a record."""
    if not isinstance(text, str):
        return None
    if text in ("", LETTER):
        return text
    return f"the letter {len(text)} times" if set(text) == {LETTER} else "the letter and other text" if LETTER in text else "other text"


def gained(was, now):
    """Has a field one letter more (or more than one) in the read `now` than in the read `was`? None: not known (a
    read of the 2 gave no text). A letter in a field with no read before the keys can be older than the keys."""
    return now.count(LETTER) > was.count(LETTER) if isinstance(now, str) and isinstance(was, str) else None


def park_of(focus):
    """The park's counts in a reply of `debug.focus`, or None when the reply has none (or a count is no number)."""
    counts = focus.get("parked_typing") if isinstance(focus, dict) else None
    try:
        return {key: int(counts.get(key) or 0) for key in PARK} if isinstance(counts, dict) else None
    except (TypeError, ValueError, OverflowError):
        return None


def park_change(before, end):
    """What the park did in a case: each count at the case's end less its count before the keys. None: a read gave
    no counts."""
    return None if before is None or end is None else {key: end[key] - before[key] for key in PARK}


def waiting(counts):
    """How many texts are in the park at a read (`park_of`): each text that came less each that left. Such a text
    waits for its page or is on its way into it. None: the read gave no counts. The counts do not say which text."""
    return None if counts is None else counts["parked"] - counts["typed"] - sum(counts[count] for count, _ in LEFT)


def noted(entries, mark, tab):
    """What the app's input journal has of a case before the select of its first new tab `tab`: the entries after
    the journal's number `mark` (the last one before the keys). Counts and the app's engine words only: no other
    text of an entry goes into a record. `readiness`: the notes of the pages' input readiness by NOTES (`focus`: a
    focus message of a page's script; `editing_on`: the script says that an editable element has the focus, which
    it sends with a document's first ready message; `key`: a key that came to a page's document). These notes name
    no page: the counts are of each page of the app. `first_new_tab`: how many times the app gave and took the
    page focus of `tab`, and the engine word of each such entry, in their order, with no word 2 times in a row (a
    word that is not of ENGINES is `other`). `page_entries`: how many entries name a page's focus, for each tab
    that has one (`each_tab`, the largest count first, with no id) and for `tab`: with entries of other tabs and
    none of `tab`, no entry has the id of `tab`, and that is not `the app changed no focus of its page`. `whole`
    False: the read was cut, and its first entries are lost."""
    every = [entry for entry in entries if isinstance(entry, dict)]
    new = [entry for entry in every if (entry.get("seq") or 0) > mark]
    kinds = [entry.get("kind") for entry in new if isinstance(entry.get("kind"), dict)]
    events = [str(part.get("event")) for part in (kind.get("content") for kind in kinds) if isinstance(part, dict) and part.get("tab") == "readiness"]
    named = [part for part in (kind.get("page") for kind in kinds) if isinstance(part, dict)]
    pages = [part for part in named if part.get("tab") == tab]
    engines = [part.get("engine") if part.get("engine") in ENGINES else "other" for part in pages]
    tabs = [repr(part.get("tab")) for part in named]
    return {"whole": not new or (every[0].get("seq") or 0) <= mark + 1, "entries": len(new),
            "page_entries": {"each_tab": sorted((tabs.count(name) for name in set(tabs)), reverse=True), "first_new_tab": len(pages)},
            "readiness": {name: sum(1 for event in events if pattern.search(event)) for name, pattern in NOTES},
            "first_new_tab": {"focus_given": sum(1 for part in pages if part.get("focused") is True),
                              "focus_taken": sum(1 for part in pages if part.get("focused") is False),
                              "engines": [word for index, word in enumerate(engines) if not index or engines[index - 1] != word]}}


def unfound(dropped, unread):
    """The word of a case that ran and whose letter no read found: `dropped` keys by the hold's log; `unread`: a
    place gave no answer."""
    return BY_HOLD if dropped else UNREAD if unread else NOWHERE


def where(first, second, before, change, dropped=0, unread=False, waited=0):
    """Where the letter of a case that ran is: each word of WHERE that is true, in the list's order (the first is
    the record's `letter_is`). `first`, `second`: the texts of the 2 new tabs' fields (None: no read, or no such
    tab); `before`: did a field of a tab that the pane showed before the keys get the letter; `change`: the park's
    counts of the case (`park_change`); `waited`: the texts in the park at the read before the select (`waiting`).
    With no such word: the ONE word of `unfound`."""
    change = change or {}
    found = ([LATE] if waited else []) + [FIELD] if LETTER in (first or "") else []
    found += [SECOND] if LETTER in (second or "") else []
    found += [BEFORE] if before else []
    found += [word for count, word in LEFT if change.get(count, 0) > 0]
    waits = change.get("parked", 0) > change.get("typed", 0) + sum(change.get(count, 0) for count, _ in LEFT)
    return found + (["parked"] if waits else []) or [unfound(dropped, unread)]


def not_read(record, place, why):
    """A place of the record that gave no answer: `place: why` in the record's `places_not_read`."""
    record.setdefault("places_not_read", []).append(f"{place}: {why}")


def moved(notes):
    """Did the close of a case move its panes? From the app's motion notes of the case (`{"text": ...}` each)."""
    return any(MOVES.search(str(note.get("text"))) for note in notes)


def verdict(form, cases):
    """A form's counts and its word: PASS, FAIL, NOT PROVED or NOT RUN. `letter_is`: how many of the form's cases
    have each word of WHERE (a word with no case is not in it). `places_not_read`: how many of its cases have a
    place that gave no answer (the word of such a case can be another one of the list: its record says which place).
    `waited_before_select`: how many of its cases had a text in the park at the last read before the tool's acts
    (each is no pass; `letter_is` says what became of the letter). `waited_first_read`: how many had a text there at
    the first read after the keys; `emptied_latest_s`: of those cases, the most seconds from the keys' call to the
    read from which the park had no text (`park_wait.empty_s`; None: no such case had such a read). These 2 are of
    each case with a `park_wait`, also of one that a later read of its wait made `not_run`."""
    ran = [case for case in cases if "pass" in case]
    chords = [case for case in ran if case["chord"]]
    moves = [case for case in ran if case.get("moved")]
    places = [case.get("letter_is", NO_RUN) for case in cases]
    emptied = [wait.get("empty_s") for wait in (case.get("park_wait") or {} for case in cases) if wait.get("first")]
    counts = {"cases": len(cases), "ran": len(ran), "not_run": len(cases) - len(ran), "chord": len(chords),
              "chord_pass": sum(case["pass"] for case in chords), "ready": len(ran) - len(chords),
              "ready_pass": sum(case["pass"] for case in ran if not case["chord"]),
              "dropped": sorted(case["dropped"] for case in ran),
              "letter_is": {word: places.count(word) for word in WHERE if word in places},
              "places_not_read": sum(1 for case in cases if case.get("places_not_read")),
              "waited_before_select": sum(1 for case in cases if case.get("waits_before_select")),
              "waited_first_read": len(emptied), "emptied_latest_s": max((at for at in emptied if at is not None), default=None),
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

    def __init__(self, builder, rpc, wait, pause=time.sleep, clock=time.monotonic):
        self.builder, self.rpc, self.wait, self.pause, self.setup_fields = builder, rpc, wait, pause, []
        self.before = []  # of a case: (tab, the text of its field) for each tab that the pane showed before the keys
        # Of the last sequence: the clock's time at the app's reply to its call, and the seconds that its steps take.
        self.clock, self.keyed, self.played_s = clock, 0.0, 0.0

    def focus(self):
        """ONE read of `debug.focus`: the hold's log, the park's counts, the app's active state, the key window."""
        reply = self.rpc("debug.focus")
        return reply if isinstance(reply, dict) else {}

    def field(self):
        reply = self.rpc("debug.new_tab", {"action": "field"})
        return reply if isinstance(reply, dict) else {}

    def journal(self, last):
        """(the reply of `debug.journal` with its last `last` entries, None), or (None, why): `no dict`, `error`,
        `no stats` (no last number), `off` (the app records no journal), or the class name of an exception."""
        try:
            reply = self.rpc("debug.journal", {"last": last})
        except Exception as error:  # noqa: BLE001  the journal takes no verdict: a failed read must not stop the case
            return None, type(error).__name__
        if not isinstance(reply, dict) or reply.get("error"):
            return None, "error" if isinstance(reply, dict) else "no dict"
        stats = reply.get("stats")
        last = stats.get("lastSeq") if isinstance(stats, dict) else None
        if isinstance(last, bool) or not isinstance(last, (int, float)) or last != last or last in (float("inf"), float("-inf")):
            return None, "no stats"
        return (None, "off") if stats.get("enabled") is False else (reply, None)

    def before_select(self, mark, why, tab):
        """The record's `journal` and `engine` for the first new tab `tab`: `noted` of the entries after `mark`, the
        journal's last number before the keys (None: that read gave none, and `why`). With no read: `not_read`."""
        reply, why = self.journal(JOURNAL_LAST) if mark is not None else (None, why)
        if reply and not isinstance(reply.get("entries"), list):
            why = "no entries"
        if why:
            return {"journal": {"not_read": why}, "engine": None}
        try:
            found = noted(reply["entries"], mark, tab)
        except Exception as error:  # noqa: BLE001  the journal takes no verdict: an entry of a form that the tool does not know must not stop the case
            return {"journal": {"not_read": type(error).__name__}, "engine": None}
        return {"journal": found, "engine": (found["first_new_tab"]["engines"] or [None])[-1]}

    @staticmethod
    def texts(counts, absent=None):
        """`waiting` of the counts of a park read, with its 2 ways to no read: a count below 0 is `not_run`, and no
        counts are `not_run` with the words `absent` (None: no counts give None, and the case goes on)."""
        waits = waiting(counts)
        if waits is None and absent:
            raise NotRun(absent)
        if waits is not None and waits < 0:
            raise NotRun(BELOW.format(waits))
        return waits

    def parked(self, record):
        """ONE read of the park after the keys: (the texts in it, the seconds from the app's reply to the call of
        the keys to this read's end). The record's `park.select` gets the read's counts, and `holds_before_select`
        the count of the windows with an open New Tab key hold (None: the reply has no such list): the record has
        those of the last such read. A read with no counts, or with a count below 0, is `not_run`."""
        focus = self.focus()
        holds = focus.get("new_tab_key_holds")
        record["park"]["select"], record["holds_before_select"] = park_of(focus), len(holds) if isinstance(holds, list) else None
        return self.texts(record["park"]["select"], NO_COUNTS), round(self.clock() - self.keyed, 3)

    def settled(self, record, mark, why, tab):
        """The last reads of what the app did with no help of the tool (THE SELECT): the texts in the park at the
        tool's last call before its own acts. While a text is in the park the case makes no other act: a read of
        the park each WAIT_STEP_S, to the first read with no text or the first one WAIT_S after the sequence's
        last key. Then the journal's read (the record's `journal` and `engine`, with the entries of the wait), and
        ONE more read of the park. With a text at that read before the bound the case waits again in the same way,
        and then reads the journal and the park again: the last read has no text, or it is at the bound or later.
        The record's `park_wait` is of each read that gave its counts: a read that stops the case is not in it, and
        a case that stops at its first read has no `park_wait`."""
        reads, bound = [], round(self.played_s + WAIT_S, 3)

        def read():
            reads.append(self.parked(record))
            empty = None
            for waits, at in reads:  # the first read with no text that has no read with a text after it
                empty = None if waits else at if empty is None else empty
            record["park_wait"] = {"first": reads[0][0], "first_s": reads[0][1], "reads": len(reads), "empty_s": empty, "last_s": reads[-1][1]}
            return reads[-1]
        waits, at = read()
        while True:
            while waits and at < bound:
                self.pause(WAIT_STEP_S)
                waits, at = read()
            record.update(self.before_select(mark, why, tab))
            waits, at = read()
            if not waits or at >= bound:
                return waits

    def text(self, pane):
        """(the text, None) of the field of the page that `pane` shows, when `pane` has the app's focus: a New Tab
        page's field, else the composer of an agent chat (the first 120 characters). With no text: (None, why),
        and why is of the composer's query: `no dict`, `error`, `no element` or `no text`."""
        text = self.field().get("text")
        if isinstance(text, str):
            return text, None
        reply = self.rpc("debug.agent_pane", {"action": "query", "pane": pane, "selector": COMPOSER})
        if not isinstance(reply, dict):
            return None, "no dict"
        found = reply.get("elements")
        if reply.get("error") or not found or not isinstance(found, list):
            return None, "error" if reply.get("error") else "no element"
        text = found[0].get("text") if isinstance(found[0], dict) else None
        return (text.strip(), None) if isinstance(text, str) else (None, "no text")

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
        self.keyed, self.played_s = self.clock(), sum(step.get("after_ms") or 0 for step in steps) / 1000
        self.pause(self.played_s + SETTLE_S)
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
        """The state of `form`: (the pane of the sequence, the pane of the new tabs, the steps). `self.before` gets
        each tab of the pane of the new tabs that the pane showed before the keys, with the text of its field and
        why that read gave no text (None: it gave one)."""
        first = self.page_tab(workspace, pane)
        self.before = [(first, "", None)]
        if form == "reselect":
            before = set(self.ids(workspace, pane))
            self.keys(pane, chord(T))
            second = next((tab for tab in self.ids(workspace, pane) if tab not in before), None)
            if not second or not self.wait(lambda: self.field().get("text") == "", 20, 0.1):
                raise NotRun("the New Tab key of the setup made no tab with a ready field")
            self.select(first, workspace, pane)
            self.select(second, workspace, pane)
            self.before = [(second, "", None), (first, "", None)]
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
            self.before = [(chat, *self.text(pane)), (first, "", None)]
        elif form in SWITCH_FORMS:
            tabs = [first]
            for tab in (first, None):  # a letter in each of the 2 tabs; the record says what each field then had
                tab or tabs.append(self.page_tab(workspace, pane))
                self.keys(pane, letter())
                self.setup_fields.append(self.field().get("text"))
            if self.setup_fields != [LETTER, LETTER]:
                raise NotRun(f"a letter of the setup did not get to its field: the 2 fields have {[seen(text) for text in self.setup_fields]}")
            self.before = [(tab, LETTER, None) for tab in tabs]
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

    def tried(self, record, place, read):
        """What `read()` read, or None with `place: why` in the record's `places_not_read`. `read()` gives (what it
        read, None) or (None, why). Its exception is a why too: the words of a NotRun (a select that the pane does
        not show), else the exception's class name only (no text of the app). A place with no read takes no verdict."""
        try:
            found, why = read()
        except NotRun as error:
            found, why = None, str(error)[:200]
        except Exception as error:  # noqa: BLE001  the case has its verdict, and one failed read must not lose the other reads
            found, why = None, type(error).__name__
        if why:
            not_read(record, place, why)
        return found

    def shows(self, tab, workspace, pane):
        """`Letters.text` of the field of `tab` after a select of it in `pane` (`pane` has the app's focus)."""
        self.select(tab, workspace, pane)
        return self.text(pane)

    def places(self, record, workspace, pane, made, first):
        """Where the letter of a case is, after the case's verdict (`first`: the text of the first new tab's field):
        the record's `second_new_tab_field`, `tabs_before`, the park's counts at the end, `letter_is` (and
        `letter_also`), and `places_not_read` for each place that gave no answer."""
        if first is None:
            not_read(record, "field", "no text")
        second = self.tried(record, "second_new_tab_field", lambda: self.shows(made[-1], workspace, pane)) if len(made) > 1 else None
        before = []
        for index, (tab, was, why) in enumerate(self.before):
            if why:
                not_read(record, f"tabs_before[{index}] before the keys", why)
            before.append((was, self.tried(record, f"tabs_before[{index}]", lambda tab=tab: self.shows(tab, workspace, pane))))
        end, park = self.tried(record, "park.end", lambda: (self.focus(), None)) or {}, record["park"]
        park.update({"end": park_of(end), "change": park_change(park["before"], park_of(end))})
        for at in ("before", "end"):
            if park[at] is None:
                not_read(record, f"park.{at}", "no parked_typing")
        record["app"]["active_end"] = end.get("app_active")
        words = where(first, second, any(gained(was, now) for was, now in before), park["change"], record["dropped"], "places_not_read" in record,
                      record["waits_before_select"])
        record.update({"second_new_tab_field": seen(second),
                       "tabs_before": [{"field_before": seen(was), "field": seen(now), "got_the_letter": gained(was, now)} for was, now in before],
                       "letter_is": words[0], **({"letter_also": words[1:]} if words[1:] else {})})

    def located(self, record, workspace, pane, made, first):
        """`places` with a guard of its own. The case has its verdict by the 2 old reads, so an exception of the
        place reads makes no `not_run`: the record's `places_not_read` gets the exception's class name only, and
        `letter_is` is of the verdict's read (the first new tab's field, the hold's dropped keys)."""
        try:
            self.places(record, workspace, pane, made, first)
        except Exception as error:  # noqa: BLE001
            not_read(record, "the places", type(error).__name__)
            record["letter_is"] = where(first, None, False, None, record["dropped"], True, record["waits_before_select"])[0]

    def case(self, form, index):
        """One case in a workspace of its own, which is closed after it: the case's record."""
        record, workspace, self.setup_fields, self.before = {"form": form, "case": index}, self.builder.new_workspace(), [], []
        try:
            if not workspace:
                raise NotRun("no new workspace")
            self.builder.show(workspace)
            pane = self.builder.panes(self.builder.workspace(workspace))[0]["id"]
            source, target, steps = self.setup(form, workspace, pane)
            had, (mark, unmarked), start = set(self.ids(workspace, target)), self.journal(1), self.focus()
            mark = None if mark is None else int(mark["stats"]["lastSeq"])
            # A text in the park before the keys is not of this case, and the counts do not say which text waits later.
            record["park"] = {"before": park_of(start)}
            record["waits_before_keys"] = waiting(record["park"]["before"])
            if self.texts(record["park"]["before"]):
                raise NotRun(OLDER.format(record["waits_before_keys"]))
            if form in MOVE_FORMS:
                self.rpc("debug.motion", {"action": "start"})
            sent = self.keys(source, steps)
            after = self.focus()
            notes = new_notes(list(start.get("new_tab_key_log") or []), list(after.get("new_tab_key_log") or []))
            record["app"] = {"active_before": start.get("app_active"), "active_after": after.get("app_active"),
                             "key_window_before": start.get("key_window"), "key_window_after": after.get("key_window")}
            record["park"]["after"] = park_of(after)
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
            # The tool's own acts on the first new tab start here (the focus of its pane, then its select): they give
            # the tab the keyboard. The reads of `settled` are the last ones of what the app did with no help of the
            # tool, and its last read of the park is the last call before these acts.
            waits = record["waits_before_select"] = self.settled(record, mark, unmarked, made[0])
            self.builder.focus_pane(target)
            self.select(made[0], workspace, target)
            text = self.wait(lambda: self.field().get("text"), 5, 0.1) or self.field().get("text")
            record.update({"field": seen(text), **judge(notes, text, waits)})
            self.located(record, workspace, target, made, text)
        except NotRun as error:
            record["not_run"] = str(error)
        except Exception as error:  # noqa: BLE001  one case that stopped must not lose the other cases
            record["not_run"] = f"the case stopped: {type(error).__name__}"  # the class name only: no text of the app
        finally:
            record.setdefault("letter_is", NO_RUN)
            if self.setup_fields:
                record["setup_fields"] = [seen(text) for text in self.setup_fields]
            if workspace:
                try:
                    self.builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
                except Exception as error:  # noqa: BLE001
                    record["workspace_not_closed"] = type(error).__name__
        return record

    def run(self, count, forms=FORMS, say=out, budget_s=BUDGET_S, now=time.monotonic):
        """`count` cases of each form, form after form: {"forms": [each form's verdict], "cases": [each record]}.
        A case that would start after `budget_s` seconds is `not_run`: the cases cannot use up the step's time."""
        report, end = {"gap_ms": GAP_MS, "budget_s": budget_s, "forms": [], "cases": []}, now() + budget_s
        late = f"the budget of the letter cases ({budget_s:.0f} s) ended before this case"
        for form in forms:
            cases = [self.case(form, index) if now() < end else {"form": form, "case": index, "not_run": late, "letter_is": NO_RUN}
                     for index in range(count)]
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
