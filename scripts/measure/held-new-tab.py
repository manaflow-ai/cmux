#!/usr/bin/env python3
"""A held Cmd-T with a Cmd-W now and then, in a session of many workspaces.

Launches a tagged Debug or bench `cmux DEV <tag>.app` with the repository's bench launcher (bench_launch.py
`BenchApp`: the bundle's own executable name, the limits of an app that launchd starts, an empty saved session for
the tag) and with the real agent pages (the launcher's mock of them is off; no agent may start). Makes a session
of --workspaces workspaces with the repository's one session maker (scripts/perf-bench/session_real.py make): each
workspace has 2 tabs, a terminal tab and a page tab at --page-url (a blank page is no row of the new tab page's
list; the default address is this host's discard port, so nothing loads from a network); --live-shells of the
terminals keep their shell, each other one is parked (the tab stays, with no pty). Then it plays 3 rows in a new
workspace whose pane has --neighbours more terminal tabs, --rounds times:

  mixed  Command down for --hold-ms; Cmd-T held, and at each --every-ms the T goes up, one Cmd-W, T again
  hold   Cmd-T held for --hold-ms, no Cmd-W
  close  Cmd-W held: one key for each tab that `hold` left

A held key is one key-down and then its repeats (the repeat flag set): the first after --repeat-delay-ms, the
next ones each --repeat-ms (default: this host's own key repeat settings). `mixed` follows the system's rule: each
new key-down of T starts its repeats again after the first delay (`mixed_repeat_rule` in the report).

KEY SOURCE. The first act is the check if a process of this step may post a key at the HID tap (`HID grant:
yes|no`; the check never asks, so no dialog). The keys come from `debug.key` (`app-queue`), in one of 2 launch
forms (--launch-form; `launch_form` and `key_source` in the report say which one the rows used, and a row's
`key_source` is the form's name):

  activate  the app is launched as a person's app (no CMUX_NEXT_NO_ACTIVATE: it takes the keyboard). A row is ONE
            `debug.key {"sequence"}` in the shell window as the key window: the app builds each key as a real
            CGEvent with its intended press time and posts it to its own event queue, so it takes `nextEvent`, the
            monitors, `sendEvent`, the key router and the action. A repeat has the repeat flag.
  one-key   the launcher's own launch (the app does not activate and has no key window). Each key-down of a row is
            ONE `debug.key {"key"}` call at its time by this script's clock, with that time as the event's time.
            The app sends it to its window directly: the app's event queue, the key-up and the repeat flag are
            NOT in the rows, so the key router's repeat path is not measured. Each call has a thread of its own:
            a call that waits for the app's main thread does not hold back the next key.
  auto      (default) `activate`; when its preflight fails, ONE new launch in the `one-key` form.

ACTIVATE. The launcher starts the app's binary directly, and on a display Mac such a process did not become the
active app. So in the `activate` form, when the app is not active after its launch, the script makes ONE
LaunchServices open of the bundle and waits 10 s for the app's `app_active`. Each launch prints `PREFLIGHT
activate: by=launch|open|none|not asked app_active=... key_window=... front=... instances=N (pids [...])`, and the
report has that line as `launch.activate`. An app that is still not active (`by=none`) ends that launch as a failed
preflight. A second instance of the app after the open ends the run with exit 1: no other launch form and no row
(the function `activate` says which process gets a signal, and when).

NOT in the measure in each form: the HID tap and the window server's delivery.

PAGE ENGINE. Directly after each launch, and one more time after the rows, the script asks the app for its own
word on the engine of its pages (`debug.cef`). The launch prints `PREFLIGHT page engine: engine=...
default_engine=... chromium_state=... unavailable=... webkit_fallbacks=N`. The report's `page_engine` has both
reads (`at_launch`, `after_the_rows`) and `engine`, the word of the read after the rows: `chromium` (the engine
says `ready`, it is the default, no page fell back), `mixed` (as `chromium`, but N pages fell back to WebKit),
`webkit` (the app says that Chromium is not available, or the default engine is WebKit), `chromium not ready`
(the engine's state is not `ready`; at the launch that can be the state of an engine that the app starts later),
`not read`. A word that is not `chromium` is no failure of the run: it says what the rows measured. See
ENGINE_LIMIT. The entry script's build requires Chromium (held-new-tab.sh).

PREFLIGHT. Directly after each launch and before the session is made, one of each act kind of a take runs in a
workspace of its own and is read back, in PREFLIGHT_S seconds at most: `frames` (1 s of `debug.frames` gives a
frame), `record` (with --film: 1 s of `debug.window_record` gives a frame), `new-tab` (one Cmd-T in the launch's
key form: the pane has one more tab), `close-tab` (one Cmd-W: one less). Each prints `PREFLIGHT <name> ok: ...`;
the first that fails prints `PREFLIGHT <name> FAILED: <the app's words>`, `debug.focus` and the window's frame, and
ends that launch. With no other launch form left the run ends at once with exit 1: a fault of the key path costs
minutes, not the time of the session's maker.

Each take follows the rule for hosts that restart bluetoothd about each 10 s: it starts 0.8 s after a new
bluetoothd pid (or after 12 s without one), `debug.frames` covers at most 8 s, and a take with a bluetoothd start
in the host's log is `disturbed` (do not use its frame tail).

Per row: keys posted, tabs made, tabs closed, keys without effect and each key's fate (burst-bench.py's accounting
from the action signposts and `debug.burst`); input to the next commit p50/p95/p99/max; `debug.frames` (missed
refreshes, the main thread's longest stop); the pane's tabs by kind at the end; the daemon's requests of the take
by command name (`server-stats` section `commands`, after minus before: the count and the handler time, which
has no wait in the connection's queue); and each record of the daemon's `slow-requests.jsonl` of the take (a
request above its threshold with `queue_ms` and `handler_ms` apart, a long lock hold). The queue time of a faster
request is in no log. `tab_shows` is the count of changes of a pane's shown tab in the take (the input journal's
`show` records: each new tab page that was the shown one at a frame is one, and so is the tab that a close uncovers).
`opens` says how many of the row's new tab pages took the page that the app keeps ready (`warm`) and how many did
not (`cold`), from `debug.new_tab`, which keeps the last OPENINGS opens only.

`order`: the pane's tab list and selected tab after the row against a small pure model of the keys that did
something: Cmd-T puts a tab directly right of the selected tab, selects it and keeps the tab it came from as its
opener; Cmd-W closes the selected tab and selects, first match, a tab it opened, a tab of the same opener, its
opener, the next tab, the previous tab. The list is the store's own (`snapshot.get`: each tab's id and kind), read
after the frames when no tab is a stand-in, or after LIST_SETTLE_S; the focus model's list (`debug.focus`) is
beside it (`focus_list_is_the_store_list`). The model knows a tab by its id: a tab of the start has its id, and a
Cmd-W on a tab that has its id is checked by the id that the app's own `closed` mark names
(`closes_checked_by_id`). The app names no id at the key that makes a tab. So a Cmd-W on a new tab is NOT checked
for which new tab it closed: the mark's id becomes that tab's id (`new_tabs.named_by_a_close`), and a new tab that
no Cmd-W closed gets its id by its place in the end list (`new_tabs.known_by_place`). `order_by` is `identity`
only when no tab got its id in one of these 2 ways, else `identity and place`. `equal` says if both agree;
`first_difference` names the first key whose close is not the model's (`where: key`), else the first place of the
end list (`list`), else the selected tab (`selected`), each with the tab's id, its kind and where it came from.
`equal` is null with its cause in `why` when the model cannot say: a key has no record of what it did (the fate
`missing` or `no_outcome`: the recording can lose a record), the end list still has a stand-in tab after
LIST_SETTLE_S, the selected tab before the keys is not known, a list or the fates are not there, or a fault of
the tool. `close` starts with the openers that `hold` left; when `hold` gave none, `close` gives no verdict and
says what `hold` did. `list_read_after_last_key_ms` is the time from the row's last key to the end of that list
read.

`slow_keys`: each key that made or closed a tab and whose first commit ended more than SLOW_KEY_MS after the key
(the slowest SLOW_KEYS of them): the key's age when its action started and the action's time, its age when that
commit started and the commit's time. `opens.main_ms`: the main thread time of the row's opens from the ready
page (`warm`) and of the others (`cold`), as the app counted each from the open action to the page in its pane.

After the rounds, ONE more `hold` take is recorded with more signpost categories (WIDE_CATEGORIES); its row has
the scenario `hold-wide` and the round `wide`, so it is in no number of the rounds' rows (a reader that groups the
rows by `scenario` lists it as a scenario of its own). `wider_recording.slow_keys` names, for each slow key, the 3
names with the most summed time between the key and the end of its first commit (a task of the main frame budget
by its class and owner; nested intervals count again); see WIDE_LIMIT.

After each row but `hold`, the workspace gets the start's shape again: first, for each tab of the start that the
row closed, the rows' pane gets a new terminal tab (`tabs_given_back`: the count that came back), then each pane
and tab that the start did not have is closed. So the restore never closes the last tab of the pane. What is
still different then is in `not_restored` and is a failure of the run. A take whose pane is gone, or whose pane
does not get the focus, has no key and no film: its row says `not_run` and why. A take whose child process does
not end in its bound (`take_bound`) is killed with its process group: its row says so, and the run ends there.

`first_frame`: for each key that made or closed a tab, was the pane's shown tab changed for that key by the end
of the first Core Animation commit after the key's action (`shown`), was a later key's action before that commit
(`superseded`: that frame had a newer state), or neither (`not_shown`). A `show` is the pane's change of its
shown tab (the input journal); that the tab's own view had its content in that frame is not in the count.

--film DIR adds one `mixed` take under `debug.window_record` (it slows the app: not for a table).

Prints one `HELD-NEW-TAB {json}` line and writes report.json to --out; with --artifact FILE it also packs the
report, each take's record and signpost stream and the film's frames into that one .tgz. Exit 0 when each row
measured what it names; 2 when a row did not and each round still has a valid row; 1 when the preflight failed or
a round has no valid row (the run ends after that round); 3 when it cannot run as asked (no report file then).
Run on a fleet GUI host (held-new-tab.sh), never on a Mac that someone works on.
"""
import argparse, ctypes, importlib.util, json, os, re, signal, socket, subprocess, sys, tarfile, threading, time, traceback
from pathlib import Path

NEXT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-next")
SPEC = importlib.util.spec_from_file_location("burst_bench", os.path.join(NEXT, "burst-bench.py"))
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)  # it puts scripts/cmux-next on sys.path
import bench_launch  # noqa: E402
import tag_teardown  # noqa: E402
STRESS = BENCH.load("perf_stress_session", "perf-stress-session.py")
BENCH.KEY["t"], BENCH.ACTIONS["t"] = 17, "newTab.default"
MAKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench", "session_real.py")
ROWS = ("mixed", "hold", "close")
REPEAT_RULE = "the system's: each new key-down of T starts its repeats again after the first delay"
SEED_LIMIT = ("the page tabs have no favicon and the terminals have one folder: the new tab page's favicon work and "
              "its list of folders are not in these rows")
ORDER_LIMIT = ("the app names no id at the key that makes a tab: a new tab gets its id from the Cmd-W that closes it, "
               "or by its place in the end list when no Cmd-W closed it; so a Cmd-W on a new tab is not checked for which "
               "new tab it closed (`closes_checked_by_id` counts only a Cmd-W on a tab that had its id), and tabs that "
               "the app made in another order are not seen while the end list has the same count; `close` starts with "
               "the openers of `hold`, each other row with none")
# A key with one of these fates has no record of what it did: the app's run of the action (`missing`) or the app's
# mark of the close (`no_outcome`) is not in the recording, which can lose a record (--allow-loss).
NO_RECORD_FATES = ("missing", "no_outcome")
STAND_IN = "pending_tab_"  # the id of a tab that the daemon does not have yet (perf-stress-session.py PROVISIONAL_TAB)
LIST_SETTLE_S = 5.0  # the wait for an end list with no stand-in tab
SLOW_KEY_MS, SLOW_KEYS = 200.0, 20
ROW_CATEGORIES = ("action",)
WIDE_CATEGORIES = ("action", "stall", "stalls", "tab-switch")
WIDE_NAME = "hold-wide"  # no comma: a reader that joins a row's labels with a comma gets one label
WIDE_LIMIT = ("one more `hold` take after the rounds, recorded with more signpost categories; it is in no number of the "
              "rounds' rows. `between`: the 3 names by summed time between a slow key and the end of its first commit "
              "(nested intervals count again, so a sum can be more than the key's own time; an interval counts only "
              "with its part inside that window); the `action` stream is not in it (the key's own action and commit "
              "are in `slow_keys`). In the `one-key` form each key is one call of the control socket, so the key's whole "
              "action runs inside the main frame budget task of that call: each such task that overlaps the window is "
              "left out, also the task of another key's call (`own_call_tasks_left_out`: the count and the ms for each "
              "slow key), and its parts have no name here. The recording of more categories can slow the app: compare "
              "this row's input to next commit with the `hold` rows")
TAKE_KILL_S = 10.0  # the wait for a killed take's child to go
ENGINE_LIMIT = ("the app's own word (`debug.cef`) at 2 times, not a read of each new tab's own view: `webkit_fallbacks` "
                "is the app's count of pages that fell back since its launch, in each window and workspace, so `mixed` "
                "does not say that a tab of the rows fell back; if the app counts a page that opened while the engine was "
                "not `ready` is not known")
FRAME_LIMIT = ("a frame is the app's Core Animation commit; `shown` is the pane's change of its shown tab, not that "
               "the tab's own view had its content; the window server's work is not in the count")
SHOWN_LIMIT = ("`shown` counts a key only when the pane's `show` record is not after the end of the key's first commit. "
               "If the app shows a new tab one frame after its open by design (a page with no view yet), that key is "
               "`not_shown` here by design and not by a fault: its delay is in `shown_after_the_commit_ms`")
# The launcher's base environment with 2 changes: the agent pages are the real ones (the mock makes a new tab page
# cheaper), and the input journal is on in each build kind (it is in a tagged build).
LAUNCH_ENV = {"CMUX_NEXT_AGENT_PANE_MOCK": None, "CMUX_NEXT_INPUT_JOURNAL": "1"}
OPENINGS = 64  # NewTabSparePool.maximumOpenings
JOURNAL = 4096  # the ring of the app's input journal: a take with more records loses its first ones
FRAMES_S = 8.0  # with the 0.8 s lead, a take stays under the 9 s between 2 bluetoothd starts
APPSERVICES = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
LOG_PREDICATE = 'process == "launchd" AND eventMessage CONTAINS "Successfully spawned bluetoothd"'
LAUNCH_FORMS = {"auto": ["activate", "one-key"], "activate": ["activate"], "one-key": ["one-key"]}
ONE_KEY = "one key for each call, no repeat flag, the script's clock"
KEY_SOURCES = {"activate": "debug.key posts real key events to the app's own queue, in the shell window as the key window, a repeat "
                           "with the repeat flag; not the HID tap, not the window server",
               "one-key": ONE_KEY + ": each key-down is one debug.key call with its intended time, sent to the window directly; "
                          "not the app's event queue, no key-up, so the key router's repeat path is not in the rows"}
PREFLIGHT_S = 120


def hid_grant():
    """May a process of this step post a key at the HID tap? None when the check itself failed."""
    try:
        check = ctypes.CDLL(APPSERVICES).CGPreflightPostEventAccess
        check.restype = ctypes.c_bool
        return bool(check())
    except (OSError, AttributeError):
        return None


def uptime():
    """Now on the clock of a key event's time (s)."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def post_keys(source, rpc, steps, pane, form):
    """The ONE key source of a take, in the launch's key form: {base_s, duration_ms} or {error}. `activate`:
    `debug.key`'s reply to the sequence, which the app plays by its own clock in the shell window as the key window.
    `one-key`: each key-down of T or W in `steps` is ONE `debug.key` call at its time by this script's clock, with
    that time as the event's time (`base_s` and the event times are on the clock of an event's time); each call has
    a thread of its own (`calls`; `replies` gets what the app said to each), so the call returns at once as the
    sequence's does. See `refused`."""
    if source != "app-queue":
        return {"error": f"the key source {source} is not in this script"}
    if form == "activate":
        return rpc("debug.key", {"sequence": steps, "key_window": "shell", "pane": pane}) or {}
    letters, downs, at = {BENCH.KEY[name]: name for name in "tw"}, [], 0.0
    for step in steps:
        at += step.get("after_ms") or 0
        if step["down"] and step["key_code"] in letters:
            downs.append((at, letters[step["key_code"]]))
    base, replies = uptime() + 0.05, [None] * len(downs)

    def press(index, offset, letter):
        time.sleep(max(0.0, base + offset / 1000 - uptime()))  # test script: the key's own time, not a settle
        replies[index] = rpc("debug.key", {"key": letter, "modifiers": ["command"], "timestamp": base + offset / 1000})

    calls = [threading.Thread(target=press, args=(index, *down), daemon=True) for index, down in enumerate(downs)]
    for call in calls:
        call.start()
    return {"base_s": base, "duration_ms": at + 50, "calls": calls, "replies": replies}


def refused(sent, bound, ran=False):
    """Why the app did not take a key of `sent` (`post_keys` in the `one-key` form), or None; `bound` s at most for
    the calls to end. `ran`: a key whose action the app did not run is a fault too (the preflight's one key); in a
    row the accounting counts it as a key without effect. None for a sequence: the app plays it."""
    end = time.monotonic() + bound
    for call in sent.get("calls") or []:
        call.join(max(0.0, end - time.monotonic()))
    for index, reply in enumerate(list(sent.get("replies") or [])):
        if not isinstance(reply, dict):
            return f"key {index}: " + (f"no reply in {bound:.0f} s" if reply is None else f"debug.key: {reply}")
        # `refused_action`: the app took the key for that action and the action did not run.
        why = reply.get("error") or (ran and reply.get("refused_action") and f"the app did not run {reply['refused_action']}")
        if why:
            return f"key {index}: {why}"
    return None


def mixed(hold_ms, every_ms, delay_ms, interval_ms):
    """The `mixed` row as key steps, with the letter and the offset (ms) of each key-down. A press of W ends
    the repeat of a held T, so each part is: T down, its repeats, T up, one Cmd-W; `gap` apart."""
    gap = max(interval_ms, 40.0)  # a fast hand's time between 2 keys
    events = []
    for index in range(int(hold_ms // every_ms)):
        down, close = index * every_ms + gap, (index + 1) * every_ms
        events.append((down, "t", True, False))
        at = down + delay_ms
        while at <= close - gap:
            events.append((at, "t", True, True))
            at += interval_ms
        events += [(close - 8, "t", False, False), (close, "w", True, False), (close + 8, "w", False, False)]
    steps, letters, offsets, last = [{"key_code": BENCH.KEY["cmd"], "down": True}], [], [], 0.0
    for at, letter, down, repeat in events:
        steps.append({"key_code": BENCH.KEY[letter], "down": down, "after_ms": at - last, **({"repeat": True} if repeat else {})})
        last = at
        if down:
            letters.append(letter)
            offsets.append(at)
    steps.append({"key_code": BENCH.KEY["cmd"], "down": False, "after_ms": 2})
    return steps, letters, offsets


def pane_order(rpc, pane):
    """`pane`'s tab ids in order, its selected tab and the focus model's word on it (`debug.focus`), or None."""
    for window in (rpc("debug.focus") or {}).get("windows") or []:
        for found in window.get("topology") or []:
            if found.get("pane") == pane:
                return {"tabs": [tab.rsplit(":", 1)[0] for tab in found.get("tabs") or []], "selected": found.get("selected"),
                        "focus_tab": (window.get("model") or {}).get("resolved_tab"),
                        "consistent": window.get("consistent"), "mismatches": window.get("mismatches")}
    return None


def pane_tabs(builder, rpc, workspace, pane, settle=0.0):
    """The store's list of `pane` (`snapshot.get`): each tab's id and kind in order and the selected tab, with the
    focus model's word on the pane (`pane_order`) beside it; None when the store has no such pane with a tab. With
    `settle` (s) it waits that long at most for a list with no stand-in tab (such an id is not the daemon's)."""
    tabs = builder.settled_tabs(workspace, pane, seconds=settle) if settle else builder.tabs(workspace, pane)
    if not tabs:
        return None
    focus = pane_order(rpc, pane) or {}
    chosen = next((tab.get("id") for tab in tabs if tab.get("selected")), None)
    return {"tabs": [tab.get("id") for tab in tabs], "kinds": [tab.get("kind") for tab in tabs],
            "selected": chosen if chosen is not None else focus.get("selected"), "selected_from": "focus" if chosen is None else "store",
            "provisional": sum(str(tab.get("id") or "").startswith(STAND_IN) for tab in tabs), "focus_tabs": focus.get("tabs"),
            **{key: focus.get(key) for key in ("focus_tab", "consistent", "mismatches")}}


def shows_of(journal, pane):
    """[the time (s, the clock of the key times), the tab] of each `show` record of `pane` in journal entries."""
    out = []
    for entry in journal:
        kind = entry.get("kind")
        for content in kind.values() if isinstance(kind, dict) else []:
            event = content.get("event") if isinstance(content, dict) else None
            if isinstance(event, str) and event.startswith(f"show pane={pane} "):
                out.append([(entry.get("uptimeNanos") or 0) / 1e9, content.get("tab")])
    return out


def oracle(tabs, selected, openers, letters, names=None):
    """The model of the keys: (the tab list, the selected tab, each tab's opener) after `letters` on a pane. A
    new tab is ("new", n): n counts the new tabs, or is the entry of `names` for it. An opener that is closed takes
    its relations with it.

    The close rule is a copy of the app's: `cmux-tui/crates/cmux-focus-core/src/close_selection.rs` and
    `Packages/macOS/CmuxNext/Sources/CmuxNextBridge/TabCloseSelection.swift`. One difference: the app gives the
    tabs that a closed tab opened to that tab's own opener, and this model drops the relation. The keys of the 3
    rows do not reach it (each tab that they close opened no tab that is still there). Tab groups are not in the
    model."""
    tabs, openers, made = list(tabs), dict(openers), 0
    for letter in letters:
        at = tabs.index(selected) if selected in tabs else None
        if letter == "t":
            made += 1
            new = ("new", names[made - 1] if names else made)
            tabs.insert(len(tabs) if at is None else at + 1, new)
            openers[new], selected = selected, new
        elif at is not None:
            near = lambda found: next((t for t in tabs[at + 1:] if found(t)), next((t for t in reversed(tabs[:at]) if found(t)), None))
            mine = openers.get(selected)
            picked = near(lambda t: openers.get(t) == selected) or (mine is not None and near(lambda t: openers.get(t) == mine)) \
                or (mine if mine in tabs else None) or (tabs[at + 1] if at + 1 < len(tabs) else tabs[at - 1] if at else None)
            tabs.pop(at)
            openers = {t: o for t, o in openers.items() if selected not in (t, o)}
            selected = picked
    return tabs, selected, openers


def closes_by_key(record):
    """{a key's index: the tab ids of its `closed` mark}: the app names each tab that a Cmd-W closed."""
    times, out = list(record.get("press_times_s") or []), {}
    bound = BENCH.press_bound(times)
    for mark in (record.get("trace") or {}).get("events") or []:
        index = BENCH.nearest(times, mark.get("event_s"), bound) if mark.get("kind") == "closed" else None
        if index is not None:
            out.setdefault(index, list(mark.get("tabs") or []))
    return out


def order_row(record, fates, openers, no_openers=None):
    """The row `order` (the docstring) and the openers that the next row starts with, by real tab id; None when
    they are not known. `openers`: the ones that this row starts with; None when the row before did not give them,
    with `no_openers` as the caller's words for the cause."""
    order = record.get("order") or {}
    before, after, letters = order.get("before"), order.get("after"), record.get("press_letters") or []
    fates = list(fates or [])
    lost = next(((index, fate) for index, fate in enumerate(fates) if fate in NO_RECORD_FATES), None)
    why = "no tab list of the pane before the keys" if not before \
        else "no tab list of the pane after the keys" if not after \
        else f"no fate of each key: {len(fates)} fates for {len(letters)} keys" if len(fates) != len(letters) \
        else f"key {lost[0]} has the fate {lost[1]}: the recording has no record of what that key did, so the model cannot follow the keys" if lost \
        else "the selected tab before the keys is not known, so the model cannot say where a new tab goes" if before.get("selected") is None \
        else f"no openers of the tabs at the start ({no_openers or 'the caller gave none'}), so the model cannot say which tab a close selects" \
        if openers is None else None
    if why:
        return {"equal": None, "why": why}, None
    kinds = {**dict(zip(before["tabs"], before.get("kinds") or [])), **dict(zip(after["tabs"], after.get("kinds") or []))}
    old, closed = set(before["tabs"]), closes_by_key(record)
    # `real`: the id of each new tab of the model, from the close that named it or from its place in the end list.
    # `by_id`: the closes of a tab that had its id before the key (the only closes that are checked by identity).
    known, real, keys, made, by_id, by_close, by_place, difference = set(old), {}, 0, 0, 0, 0, 0, None

    def words(tab):
        if tab is None:
            return None
        if isinstance(tab, tuple):
            return {"tab": real.get(tab), "kind": kinds.get(real.get(tab)), "from": f"key {tab[1]} of the row"}
        maker = next((new for new, ident in real.items() if ident == tab), None)
        where = "before the row" if tab in old else f"key {maker[1]} of the row" if maker else "the row, its key is not known"
        return {"tab": tab, "kind": kinds.get(tab), "from": where}

    tabs, selected, opened = list(before["tabs"]), before["selected"], dict(openers)
    for index, (letter, fate) in enumerate(zip(letters, fates)):
        if fate not in BENCH.APPLIED_FATES:
            continue
        keys += 1
        if letter == "w":
            got = closed.get(index) or []
            if not isinstance(selected, tuple) or selected in real:
                by_id += 1
            elif len(got) == 1 and got[0] not in known:
                # A naming, not a check: the mark's id becomes the id of the model's selected new tab.
                real[selected] = got[0]
                known.add(got[0])
                by_close += 1
            if got != [real.get(selected, selected)]:
                difference = {"where": "key", "key": index, "letter": letter, "expected": words(selected), "got": [words(tab) for tab in got]}
                break
        else:
            made += 1
        tabs, selected, opened = oracle(tabs, selected, opened, letter, names=[index])
    end = after["tabs"]
    for at in range(max(len(tabs), len(end)) if difference is None else 0):
        want, got = tabs[at] if at < len(tabs) else None, end[at] if at < len(end) else None
        if isinstance(want, tuple) and want not in real and got is not None and got not in known:
            real[want] = got
            known.add(got)
            by_place += 1
        if got is None or real.get(want, want) != got:
            difference = {"where": "list", "place": at, "expected": words(want), "got": words(got)}
            break
    if difference is None and real.get(selected, selected) != after["selected"]:
        difference = {"where": "selected", "expected": words(selected), "got": words(after["selected"])}
    stand_ins = sum(str(tab).startswith(STAND_IN) for tab in end)
    focus = after.get("focus_tabs")
    row = {"equal": difference is None, "order_by": "identity and place" if by_close or by_place else "identity",
           "limit": ORDER_LIMIT, "keys_in_the_model": keys, "tabs_before": len(before["tabs"]), "tabs": len(end),
           "expected_tabs": None if difference and difference["where"] == "key" else len(tabs), "first_difference": difference,
           "closes_checked_by_id": by_id, "new_tabs": {"made": made, "named_by_a_close": by_close, "known_by_place": by_place},
           "selected": after["selected"], "selected_from": after.get("selected_from"), "provisional_after": stand_ins,
           "focus_list_is_the_store_list": None if focus is None else focus == end, "focus_tabs": None if focus is None else len(focus),
           "focus_is_the_selected_tab": after.get("focus_tab") == after["selected"], "focus_consistent": after.get("consistent"),
           "focus_mismatches": after.get("mismatches")}
    if stand_ins and not (difference and difference["where"] == "key"):
        # A stand-in's id is not the daemon's, and its tab can still move: the list says nothing yet. A close of a
        # tab that had its id and was not the model's stays `not equal`.
        row.update({"equal": None, "why": f"{stand_ins} stand-in tabs in the end list {LIST_SETTLE_S:.0f} s after the keys: the list is not final"})
    if difference or stand_ins:
        return row, None
    return row, {real.get(t, t): real.get(o, o) for t, o in opened.items() if t in tabs and o in tabs}


def read_stream(signposts, ndjson):
    with open(ndjson) as f:
        return signposts.parse(f.read().splitlines(), signposts.local_timebase())["intervals"]


def key_runs(intervals, record):
    """{a key's index: {"perform": its first run, "commit": its first commit}} from the user intervals of the keys'
    actions (the `action` stream), each given to the key of its event time."""
    letters, times, out = record.get("press_letters") or [], list(record.get("press_times_s") or []), {}
    ids, bound = {BENCH.ACTIONS[p] for p in letters}, BENCH.press_bound(times)
    for interval in intervals:
        fields, part = interval["fields"], {"action.perform": "perform", "action.commit": "commit"}.get(interval["name"])
        if not part or fields.get("id") not in ids or fields.get("origin") != "user" or interval.get("missed") \
                or float(fields.get("input_age_ms", "-1")) < 0:
            continue
        index = BENCH.nearest(times, BENCH.event_time(interval), bound)
        if index is not None and (part not in out.setdefault(index, {}) or interval["at_s"] < out[index][part]["at_s"]):
            out[index][part] = interval
    return out


def slow(runs, fates):
    """[(a key's index, its first commit, the ms from the key to that commit's end)] of each key that made or closed
    a tab and whose first commit ended more than SLOW_KEY_MS after the key, the slowest first."""
    found = []
    for index in sorted(runs):
        commit = runs[index].get("commit")
        total = float(commit["fields"]["input_age_ms"]) + commit["ms"] if commit else 0.0
        if total > SLOW_KEY_MS and fates[index] in BENCH.APPLIED_FATES:
            found.append((index, commit, total))
    return sorted(found, key=lambda key: -key[2])


def slow_keys(runs, record, fates):
    """The row `slow_keys` (the docstring)."""
    letters, found = record.get("press_letters") or [], slow(runs, fates)
    age = lambda interval: round(float(interval["fields"]["input_age_ms"]), 2) if interval else None
    keys = [{"key": index, "letter": letters[index], "fate": fates[index], "key_to_commit_ms": round(total, 2),
             "age_at_action_start_ms": age(runs[index].get("perform")),
             "action_ms": round(runs[index]["perform"]["ms"], 2) if runs[index].get("perform") else None,
             "age_at_commit_start_ms": age(commit), "commit_ms": round(commit["ms"], 2)} for index, commit, total in found[:SLOW_KEYS]]
    return {"over_ms": SLOW_KEY_MS, "count": len(found), "keys": keys}


def between(intervals, runs, record, fates, form):
    """The wider recording's slow keys (WIDE_LIMIT): ([{key, key_to_commit_ms, between: the 3 names with the most
    summed time, own_call_tasks_left_out: {count, ms} of this key's window}], the count of the control call tasks
    that were left out in all windows)."""
    times, out, own = list(record.get("press_times_s") or []), [], 0
    for index, commit, total in slow(runs, fates)[:SLOW_KEYS]:
        start, end, sums, left = times[index], commit["at_s"] + commit["ms"] / 1000, {}, [0, 0.0]
        for interval in intervals:
            ms = (min(end, interval["at_s"] + interval["ms"] / 1000) - max(start, interval["at_s"])) * 1000
            if interval["category"] == "action" or ms <= 0:
                continue
            fields = interval["fields"]
            if form == "one-key" and "debug.key" in str(fields.get("owner") or ""):
                own, left = own + 1, [left[0] + 1, left[1] + ms]
                continue
            name = interval["name"] if interval["name"].startswith(interval["category"] + ".") else f"{interval['category']}.{interval['name']}"
            what = " ".join([name] + [f"{key}={fields[key]}" for key in ("class", "owner") if key in fields])
            sums[what] = (sums.get(what, (0.0, 0))[0] + ms, sums.get(what, (0.0, 0))[1] + 1)
        top = sorted(sums.items(), key=lambda item: -item[1][0])[:3]
        out.append({"key": index, "key_to_commit_ms": round(total, 2),
                    "between": [{"what": what, "ms": round(ms, 1), "count": count} for what, (ms, count) in top],
                    "own_call_tasks_left_out": {"count": left[0], "ms": round(left[1], 1)}})
    return out, own


def opens_of(last):
    """The row `opens` from the app's records of the row's opens (`debug.new_tab`)."""
    def part(spare):
        values = [o["ms"] for o in last if o.get("spare") is spare and isinstance(o.get("ms"), (int, float))]
        return {**(BENCH.percentiles(values) or {"n": 0}), "sum": round(sum(values), 1)}
    return {"warm": sum(o.get("spare") is True for o in last), "cold": sum(o.get("spare") is False for o in last),
            "known_of_the_last": OPENINGS, "main_ms": {"warm": part(True), "cold": part(False)}}


def restore(builder, workspace, pane, state):
    """The start's shape again after a row: (the start state for the next row, what is still different, the count
    of tabs that came back). A tab of the start that the row CLOSED does not come back by a close, so FIRST, for
    each one, the rows' pane gets a new terminal tab (a new id: the returned state has it). THEN burst-bench.py's
    restore closes each pane and tab that the start did not have. In this order the restore never closes the last
    tab of the pane (a pane with no tab can go). Nothing is given back when the pane is gone."""
    seen = BENCH.start_state(builder, workspace)
    here = seen.get(pane)
    lost, why, came = len(state[pane] - here) if here is not None else 0, [], set()
    if lost:
        try:
            for _ in range(lost):
                builder.add_tab(workspace, pane, "terminal")
        except RuntimeError as error:  # the session helper's class for a tab that did not appear or stayed a stand-in
            why = [f"a tab of the start did not come back: {error}"]
        came = (BENCH.start_state(builder, workspace).get(pane) or set()) - here
        if not why and len(came) != lost:
            why = [f"pane {pane}: {len(came)} new tabs after the give-back of {lost} tabs of the start"]
    want = {**state, pane: (state[pane] & here) | came} if lost else state
    left = why + BENCH.restore(builder, STRESS, workspace, pane, want)
    return (state if left else want), left, len(came)


def pack(out, film, target):
    """ONE file for a step to bring back (a step's command names one artifact): the report, each take's record and
    signpost stream, and with a film its frames.json and each fifth frame. Returns the names in it."""
    names = {f"{found.parent.name}/{found.name}": found
             for found in sorted(Path(out).glob("*/scenario.json")) + sorted(Path(out).glob("*/run.ndjson"))}
    if (Path(out) / "report.json").exists():
        names["report.json"] = Path(out) / "report.json"
    frames = Path(film) / "frames" if film else None
    if frames and (frames / "frames.json").exists():
        names.update({f"film/{found.name}": found for found in [frames / "frames.json"] + sorted(frames.glob("frame-*[05].jpg"))})
    with tarfile.open(target, "w:gz") as tar:
        for name, found in names.items():
            tar.add(found, arcname=name)
    return list(names)


def first_frame(signposts, ndjson, record, fates):
    """For each key that made or closed a tab: its first commit against the pane's `show` records (the docstring)."""
    with open(ndjson) as f:
        parsed = signposts.parse(f.read().splitlines(), signposts.local_timebase())
    letters, times = record.get("press_letters") or [], list(record.get("press_times_s") or [])
    ids, bound, commits = {BENCH.ACTIONS[p] for p in letters}, BENCH.press_bound(times), {}
    for interval in parsed["intervals"]:
        fields = interval["fields"]
        if interval["name"] != "action.commit" or fields.get("id") not in ids or fields.get("origin") != "user" or interval.get("missed"):
            continue
        index = BENCH.nearest(times, BENCH.event_time(interval), bound)
        if index is not None and fates[index] in BENCH.APPLIED_FATES and (index not in commits or interval["at_s"] < commits[index][0]):
            commits[index] = (interval["at_s"], interval["at_s"] + interval["ms"] / 1000)
    keys, shown, late = sorted(commits), {}, []
    for at, _ in record.get("shows") or []:
        owner = next((k for k in reversed(keys) if commits[k][0] <= at), None)  # the newest key whose action ran before it
        if owner is not None:
            shown.setdefault(owner, at)
    out = {letter: {"keys": 0, "shown": 0, "superseded": 0, "not_shown": 0} for letter in sorted(set(letters))}
    for position, key in enumerate(keys):
        counts, end = out[letters[key]], commits[key][1]
        counts["keys"] += 1
        if key in shown and shown[key] <= end:
            counts["shown"] += 1
        elif position + 1 < len(keys) and commits[keys[position + 1]][0] <= end:
            counts["superseded"] += 1
        else:
            counts["not_shown"] += 1
            late += [(shown[key] - end) * 1000] if key in shown else []
    applied = sum(fate in BENCH.APPLIED_FATES for fate in fates)
    return {"by_key": out, "keys_with_no_commit": applied - len(keys), "shown_after_the_commit_ms": BENCH.percentiles(late),
            "show_records": len(record.get("shows") or []), "limit": FRAME_LIMIT, "shown_limit": SHOWN_LIMIT}


def bluetoothd():
    return subprocess.run(["pgrep", "-x", "bluetoothd"], capture_output=True, text=True).stdout.split()


def bluetoothd_starts(start, end):
    """The bluetoothd starts in the host's own log between 2 wall times; None when the log cannot be read."""
    stamp = lambda t: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
    try:
        done = subprocess.run(["/usr/bin/log", "show", "--start", stamp(start - 1), "--end", stamp(end + 2), "--style", "compact",
                               "--predicate", LOG_PREDICATE], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    found = 0
    for line in done.stdout.splitlines():
        try:
            at = time.mktime(time.strptime(line[:19], "%Y-%m-%d %H:%M:%S")) + float("0" + line[19:23])
        except ValueError:
            continue  # the header line
        found += start <= at <= end
    return found


def take(opts):
    """One row on the running app (the child of perf-signposts.py); writes scenario.json to --out."""
    rpc = STRESS.socket_rpc(opts.socket)
    builder = STRESS.Stress(rpc, log=lambda line: None)
    builder.measured = opts.workspace
    record = {"scenario": opts.row, "errors": [], "invalid": [], "unit": "tabs",
              "key_window": "shell" if opts.launch_form == "activate" else "none"}
    tabs = lambda: builder.tabs(opts.workspace, opts.pane)
    count = lambda: {"tabs": len(tabs()), "panes": len(builder.panes(builder.workspace(opts.workspace)))}
    try:
        builder.focus_pane(opts.pane)  # waits for the focus model to name the pane
    except STRESS.StressShapeError as error:
        # No key and no film without the focus of the rows' pane: the keys would act on another pane.
        record["not_run"] = f"the pane of the rows did not get the focus: {error}"
        with open(os.path.join(opts.out, "scenario.json"), "w") as f:
            json.dump(record, f, indent=1)
        return 0
    before, order = count(), {"before": pane_tabs(builder, rpc, opts.workspace, opts.pane)}
    # Each journal and `debug.focus` read is outside the frame take: before it starts or after it ends.
    seen = ((rpc("debug.journal", {"last": 1}) or {}).get("stats") or {}).get("lastSeq")
    first = bluetoothd()
    fresh = bool(STRESS.wait(lambda: bluetoothd() != first, 12, step=0.05))
    time.sleep(0.8)  # test script: the stall of a bluetoothd start is over before this
    first, start = bluetoothd(), time.time()
    rpc("debug.frames", {"action": "start"})
    armed = rpc("debug.burst", {"action": "start"}) or {}
    delay = opts.repeat_delay_ms or float(armed.get("key_repeat_delay_s") or 0) * 1000
    interval = opts.repeat_ms or float(armed.get("key_repeat_interval_s") or 0) * 1000
    if armed.get("error") or not (delay and interval):
        record["errors"].append(f"debug.burst gave no recording or no key repeat: {armed}")
        delay, interval = delay or 500.0, interval or 83.0
    if opts.row == "mixed":
        steps, letters, offsets = mixed(opts.hold_ms, opts.every_ms, delay, interval)
    else:
        made = before["tabs"] - opts.keep
        letters = ["w"] * made if opts.row == "close" else ["t"] * (2 + int(max(0, opts.hold_ms - delay) // interval))
        if not letters:
            record["errors"].append("no tab to close")
            letters = ["w"]
        steps, offsets = BENCH.sequence(letters, 0, (delay, interval))
    if opts.film:
        rpc("debug.window_record", {"dir": opts.film, "seconds": min(12.0, opts.hold_ms / 1000 + 2)})
    sent = post_keys(opts.keys, rpc, steps, opts.pane, opts.launch_form)
    if sent.get("error") or "base_s" not in sent:
        record["errors"].append(f"keys: {sent}")
    duration, began = float(sent.get("duration_ms") or 0) / 1000, time.monotonic()
    time.sleep(duration)  # test script: the sequence's own schedule, not a settle

    def done():
        reply = rpc("debug.burst", {"action": "status"}) or {}
        return (reply.get("recording") and not reply.get("sequence_playing") and reply.get("pending_intents") == 0
                and reply.get("resize_idle") and reply.get("terminals_awaiting_echo") == 0)

    in_take = STRESS.wait(done, max(0.5, FRAMES_S - duration), step=0.1)
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    end, moved = time.time(), bluetoothd() != first
    if not (in_take or STRESS.wait(done, opts.deadline, step=0.1)):
        record["invalid"].append(f"the app never said the burst was done within {opts.deadline:.0f} s more")
    settled_ms = round((time.monotonic() - began) * 1000)
    why = refused(sent, opts.deadline)
    if why:
        record["errors"].append(f"keys: {why}")
    trace = rpc("debug.burst", {"action": "stop"}) or {}
    journal = [] if seen is None else [e for e in (rpc("debug.journal", {"last": JOURNAL}) or {}).get("entries") or [] if (e.get("seq") or 0) > seen]
    shows = sum(e.startswith("show pane=") for e in re.findall(r'"event":\s*"([^"]*)"', json.dumps(journal)))
    order["after"] = pane_tabs(builder, rpc, opts.workspace, opts.pane, settle=LIST_SETTLE_S)
    list_read = uptime()
    if opts.film and not STRESS.wait(lambda: os.path.exists(os.path.join(opts.film, "frames.json")), 20, step=0.2):
        record["errors"].append("the film has no frames.json")
    starts = bluetoothd_starts(start, end)
    kinds = {}
    for tab in tabs():
        kinds[tab.get("kind")] = kinds.get(tab.get("kind"), 0) + 1
    base = sent.get("base_s")
    times = [base + o / 1000 for o in offsets] if isinstance(base, (int, float)) else []
    record.update({"presses": len(letters), "before": before, "after": count(), "press_letters": letters, "press_times_s": times,
                   "key_repeat": {k: armed.get(k) for k in ("key_repeat_delay_s", "key_repeat_interval_s")},
                   "held_repeat_ms": [delay, interval], "trace": trace, "sequence_ms": duration * 1000,
                   "frames": {k: frames.get(k) for k in BENCH.FRAME_FIELDS}, "settled_ms": settled_ms,
                   "tabs_after": [t.get("id") for p in builder.panes(builder.workspace(opts.workspace)) for t in p.get("tabs") or []],
                   "order": order, "shows": shows_of(journal, opts.pane),
                   "take": {"tabs_by_kind_after": kinds, "settled_inside_the_frames": bool(in_take), "key_form": opts.launch_form,
                            "actions_not_run_by_reply": sum(1 for r in sent.get("replies") or [] if isinstance(r, dict) and r.get("refused_action")),
                            "tab_shows": shows if journal else None, "tab_shows_whole": bool(journal) and journal[0].get("seq") == seen + 1,
                            "tab_shows_ring": JOURNAL,
                            "list_read_after_last_key_ms": round((list_read - times[-1]) * 1000, 1) if times else None,
                            "bluetoothd": {"new_pid_before": fresh, "pid_changed": moved, "log_starts": starts},
                            "disturbed": bool(moved or starts)}})
    with open(os.path.join(opts.out, "scenario.json"), "w") as f:
        json.dump(record, f, indent=1)
    return 0


def valid(row):
    return not (row.get("errors") or row.get("invalid"))


def daemon(path, message, timeout=60.0):
    """One request to the daemon on a connection of its own: (the reply or None, its ms)."""
    message = {"id": "held-new-tab", **message}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            sent, data = time.monotonic(), b""
            conn.sendall(json.dumps(message).encode() + b"\n")
            while True:
                while b"\n" not in data:
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        return None, None
                    data += chunk
                line, data = data.split(b"\n", 1)
                value = json.loads(line)
                if isinstance(value, dict) and value.get("id") == message["id"]:
                    return value, (time.monotonic() - sent) * 1000
    except (OSError, ValueError):
        return None, None


def daemon_of(app):
    """(the socket, the state folders) of the daemon that the app started from its bundle."""
    for pid, command in (app.teardown.processes() if app.teardown else []):
        found = tag_teardown.procargs(pid) if "--headless" in command else None
        if found and "--socket" in found[0][:-1]:
            return found[0][found[0].index("--socket") + 1], sorted(app.teardown.state_roots)
    return None, []


def seed(app, count, live, url, deadline, out):
    """`count` workspaces by session_real.py `make` on the app's daemon, each with a terminal tab (parked, so no
    pty, but for `live` of them) and a page tab at `url`: (its result or {}, its exit code or why it has none, the count of
    workspaces that it said it made, its last lines). Its output goes to this script's output."""
    result = os.path.join(out, "session.json")
    command = [sys.executable, MAKER, "make", "--app-socket", app.socket, "--workspaces", str(count), "--terminals", str(count),
               "--agents", "0", "--no-agents", "--settle", "0", "--tabs", str(2 * count), "--panes", str(count),
               "--browser-tabs", str(count), "--browser-url", url, "--live-shells", str(live), "--out", result]
    try:
        done = subprocess.run(command, check=False, timeout=deadline, capture_output=True, text=True)
        code, said = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as late:
        parts = [part.decode(errors="replace") if isinstance(part, bytes) else part or "" for part in (late.stdout, late.stderr)]
        code, said = f"not done in {deadline:.0f} s", "".join(parts)
    print(said, flush=True)
    counted = re.findall(r"^made (\d+)/", said, re.M)
    try:
        with open(result) as f:
            made = json.load(f)
    except (OSError, ValueError):
        made = {}
    return made, code, int(counted[-1]) if counted else 0, said.strip().splitlines()[-3:]


def stats(path):
    reply, _ = daemon(path, {"cmd": "server-stats", "include": ["commands"]}, 10.0)
    return ((reply or {}).get("data") or {}).get("commands") or {}


def requests_between(before, after):
    """The daemon's requests between 2 reads of `server-stats`, by command name and client kind: the count, the
    mean handler ms, and the upper bound (ms) of the histogram bucket of the p95 and of the slowest."""
    bounds = [b / 1e6 for b in after.get("hist_bounds_ns") or []]
    old = {(r["name"], r["kind"]): r for r in before.get("rows") or []}
    out = []
    for row in after.get("rows") or []:
        was = old.get((row["name"], row["kind"]), {})
        n = row["count"] - was.get("count", 0)
        if n <= 0:
            continue
        hist = [a - b for a, b in zip(row["hist"], was.get("hist") or [0] * len(row["hist"]))]
        top = lambda q: next((bounds[i] if i < len(bounds) else None for i in range(len(hist)) if sum(hist[:i + 1]) >= q * n), None)
        out.append({"name": row["name"], "client": row["kind"], "count": n, "p95_below_ms": top(0.95), "max_below_ms": top(1.0),
                    "mean_ms": round((row["total_ns"] - was.get("total_ns", 0)) / n / 1e6, 3)})
    return sorted(out, key=lambda r: -r["mean_ms"] * r["count"])


def slow_records(roots, start, end):
    """The records of the daemon's slow request log between 2 wall times."""
    out = []
    for file in (f for root in roots for f in Path(root).rglob("slow-requests.jsonl*")):
        for line in file.read_text(errors="replace").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if start * 1000 <= record.get("at_ms", 0) <= end * 1000:
                out.append({k: v for k, v in record.items() if k not in ("side", "at")})
    return out


class PreflightFailed(RuntimeError):
    pass


# `SecondInstance`, `front_app`, `instances` and `activate` are a copy of pane-motion-films.py's (the same launch on
# the same hosts); but for 2 places where the words name a film, the text is the same. A change of one is a change
# of both.
class SecondInstance(PreflightFailed):
    """A second instance of the app runs after the LaunchServices open: no other launch form, no row."""


def place(app):
    """The `activate` form: the app reads no window placement at its launch, so the window gets the launcher's frame
    (its x, y from the top left of the main screen's visible frame) here. Returns the frame, or why not."""
    first = app.rpc("debug.window_frame", {"screen": 0})
    visible = first.get("visible_frame") if isinstance(first, dict) else None
    if not visible:
        return f"not placed: {str(first)[:160]}"
    width, height = min(app.window[2], visible[2]), min(app.window[3], visible[3])
    x, y = min(app.window[0], visible[2] - width), min(app.window[1], visible[3] - height)
    reply = app.rpc("debug.window_frame", {"frame": [visible[0] + x, visible[1] + visible[3] - y - height, width, height]})
    return reply.get("frame") if isinstance(reply, dict) and reply.get("frame") else f"not placed: {str(reply)[:160]}"


def front_app():
    """The frontmost app of this session by LaunchServices (`lsappinfo front`, then its name and its pid), or the
    tool's own words when it gives none."""
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, errors="replace", timeout=5).stdout.strip()
        name, pid = (subprocess.run(["/usr/bin/lsappinfo", "info", "-only", only, asn], capture_output=True, text=True, errors="replace",
                                    timeout=5).stdout.strip() for only in ("name", "pid"))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return f"not read ({str(error)[:80]})"
    named, numbered = re.search(r'=\s*"([^"]*)"', name), re.search(r'"?pid"?\s*=\s*(\d+)', pid)
    return f"{named.group(1) if named else (name or asn)[:60] or 'none'} (pid {numbered.group(1) if numbered else 'not read'})"


def instances(binary):
    """The running instances of the app `binary`, as {pid: (its parent's pid, the first 120 characters of its
    command)}: each process of that exact path that is not a child of another process of it (LaunchServices starts an
    instance under launchd, pid 1; this run's instance is a child of this script). None when `ps` gave no list (no
    answer in 10 s, an exit that is not 0, words that do not parse): that fault is printed, and the caller then
    counts nothing and sends no signal."""
    try:
        done = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, errors="replace", timeout=10)
        if done.returncode:
            raise OSError(f"exit {done.returncode}: {done.stderr.strip()[:120]}")
        paths = {binary, os.path.realpath(binary)}
        rows = (line.split(None, 2) for line in done.stdout.splitlines())
        own = {int(row[0]): (int(row[1]), row[2][:120]) for row in rows
               if len(row) == 3 and any(row[2] == path or row[2].startswith(path + " ") for path in paths)}
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"PREFLIGHT activate: ps gave no list of the app's instances: {str(error)[:200]}", flush=True)
        return None
    return {pid: row for pid, row in sorted(own.items()) if row[0] not in own}


def activate(app, form):
    """Prints `PREFLIGHT activate: by=... app_active=... key_window=... front=... instances=N (pids [...])` and
    returns it; then one line for each instance (its parent and its command). The launcher starts the app's binary
    directly, and on a display Mac such a process did not become the active app. So in the `activate` form, if the
    app is not active after its launch: ONE LaunchServices open of the bundle (`open BUNDLE`; for an app that runs,
    the open makes that instance the active app, as a click on its Dock icon does; close-flash-bench.py activates its
    app the same way), then 10 s for `app_active`. `by` = `launch` (active with no open), `open`, `none` (not
    active: the whole `debug.focus` reply is printed, and PreflightFailed with the line), `not asked` (the `one-key`
    form: its launch never takes the keyboard). A `ps` that gives no list is `instances=not read`: it ends nothing.

    A second instance: a pid in the list after the open that was not in the list before it and is not the process
    of this launch. It raises SecondInstance with the line: the run ends there, and no row is measured with an app on
    the display that is not this run's. Such a pid gets ONE SIGTERM from this function (no other signal, no second
    try) only when the list before the open was read, the process of this launch was in it (so the list is proven),
    and the pid's parent is pid 1 (what LaunchServices starts): it would stay in the session after the run. In each
    other case the line says `SIGTERM not sent` with the cause. Not of this function: at the end of each launch the
    launcher's stop ends each process of this bundle path that still runs (SIGTERM, then SIGKILL), as it always did."""
    focus = lambda: (lambda reply: reply if isinstance(reply, dict) else {})(app.rpc("debug.focus"))
    own = getattr(getattr(app, "process", None), "pid", None)
    by, asked, before = "not asked", False, None
    if form == "activate":
        by = "launch"
        if not focus().get("app_active"):
            asked, before = True, instances(app.binary)
            try:
                opened = subprocess.run(["/usr/bin/open", app.app], capture_output=True, text=True, errors="replace", timeout=30)
                if opened.returncode:
                    print(f"PREFLIGHT activate: open exit {opened.returncode}: {opened.stderr.strip()[:200]}", flush=True)
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                print(f"PREFLIGHT activate: open did not run: {str(error)[:200]}", flush=True)
            by = "open" if STRESS.wait(lambda: focus().get("app_active"), 10, step=0.25) else "none"
    seen, front = focus(), front_app()  # the front app first: the list of instances is then new when a signal goes
    running = instances(app.binary)
    listed = lambda table: "not read" if table is None else sorted(table)
    inner = ([f"pids {listed(running)}"] if running is not None else []) + ([f"before the open: {listed(before)}"] if asked else [])
    line = (f"PREFLIGHT activate: by={by} app_active={str(bool(seen.get('app_active'))).lower()} key_window={seen.get('key_window') or 'none'} "
            f"front={front} instances={'not read' if running is None else len(running)}" + (f" ({'; '.join(inner)})" if inner else ""))
    print(line, flush=True)
    for pid, (parent, command) in (running or {}).items():
        print(f"PREFLIGHT activate: instance pid {pid}: parent {parent}, command {command}", flush=True)
    new = [pid for pid in (running or {}) if pid not in (before or {}) and pid != own] if asked else []
    if new:
        unproven = ("the list before the open was not read" if before is None
                    else f"the launched pid {own} was not in the list before the open" if own not in before else "")
        ended = []
        for pid in new:
            parent, command = running[pid]
            why = unproven or (f"its parent is pid {parent}, not pid 1" if parent != 1 else "")
            if not why:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError as error:
                    why = str(error)[:80]
            ended.append(f"pid {pid} (parent {parent}, command {command}): SIGTERM {f'not sent ({why})' if why else 'sent'}")
        stop = f"a second instance of the app runs after the open; one SIGTERM to each one that launchd started: {'; '.join(ended)}; the run ends here"
        print("PREFLIGHT activate: " + stop, flush=True)
        raise SecondInstance(f"{line}: {stop}")
    if by == "none":
        print("PREFLIGHT activate: debug.focus = " + json.dumps(seen, default=str)[:2000], flush=True)
        raise PreflightFailed(line)
    return line


def preflight(app, st, out, film, form, display):
    """One of each act kind of a take, in a workspace of its own, each read back: `frames`, `record` (with a film),
    `new-tab`, `close-tab`, the keys in the launch's key form. Prints the state of the launch, then
    `PREFLIGHT <name> ok: <what was read>` for each, then returns the display link's reply; the first that fails
    prints the app's words, `debug.focus` and the window's frame, and raises. PREFLIGHT_S at most."""
    rpc, began, name, passed = app.rpc, time.monotonic(), "launch", []

    def wait(test, bound, step):
        return STRESS.wait(test, max(0.2, min(bound, began + PREFLIGHT_S - time.monotonic())), step=step)

    def fail(said):
        late = f" (the preflight's {PREFLIGHT_S} s are over)" if time.monotonic() - began > PREFLIGHT_S else ""
        print(f"PREFLIGHT {name} FAILED: {str(said)[:400]}{late}", flush=True)
        print("PREFLIGHT focus: " + json.dumps(rpc("debug.focus"))[:2000], flush=True)
        print("PREFLIGHT window: " + json.dumps(rpc("debug.window_frame", {}))[:600], flush=True)
        raise PreflightFailed(f"{name}: {str(said)[:300]}")

    def ok(said):
        passed.append(name)
        print(f"PREFLIGHT {name} ok: {said}", flush=True)

    focus = rpc("debug.focus")
    focus = focus if isinstance(focus, dict) else {}
    print(f"PREFLIGHT launch: activate={'yes' if form == 'activate' else 'no'} app_active={str(bool(focus.get('app_active'))).lower()} "
          f"key_window={focus.get('key_window') or 'none'} display={display}", flush=True)
    name = "frames"
    rpc("debug.frames", {"action": "start"})
    time.sleep(1.0)  # test script: 1 s of the app's display link, the rate that the display has for this app
    link = rpc("debug.frames", {"action": "stop"})
    link = link if isinstance(link, dict) else {}
    if not link.get("frames"):
        fail(f"the display link gave no frame in 1 s: {link}")
    ok(f"frames {link.get('frames')}, p50 {link.get('p50_ms')} ms")
    workspace = st.new_workspace()
    if workspace:
        st.show(workspace)
    pane = workspace and wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 20, 0.05)
    name = "record"
    if not pane:
        fail(f"no new workspace with a pane (workspace {workspace})")
    st.focus_pane(pane)
    if film:
        folder = os.path.join(out, "preflight-film")

        def filmed():
            try:
                with open(os.path.join(folder, "frames.json")) as f:
                    return len(json.load(f).get("times") or [])
            except (OSError, ValueError):
                return 0

        started = rpc("debug.window_record", {"dir": folder, "seconds": 1})
        if not isinstance(started, dict) or started.get("error"):
            fail(f"debug.window_record: {started}")
        if not wait(filmed, 10, 0.2):
            fail("debug.window_record gave no frames.json with a frame in 10 s")
        ok(f"frames {filmed()}")
    tabs = lambda: len(st.tabs(workspace, pane))
    for name, letter, change in (("new-tab", "t", 1), ("close-tab", "w", -1)):
        before = tabs()
        sent = post_keys("app-queue", rpc, BENCH.sequence([letter], 0)[0], pane, form)
        why = sent.get("error") or ("base_s" not in sent and f"debug.key gave no start time: {sent}") or refused(sent, 10, ran=True)
        if why:
            fail(why)
        if not wait(lambda: tabs() == before + change, 10, 0.05):
            fail(f"tabs {before} -> {tabs()} in 10 s, not {before + change}")
        ok(f"tabs {before} -> {tabs()}")
    st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
    st.made.clear()
    wait(lambda: not st.workspace(workspace), 10, 0.1)  # the session's count starts without it; a late close is no fault
    name = "time"
    if time.monotonic() - began > PREFLIGHT_S:
        fail(f"each check passed, in {time.monotonic() - began:.0f} s")
    print(f"PREFLIGHT passed: {', '.join(passed)} in {time.monotonic() - began:.0f} s", flush=True)
    return link


def page_engine(rpc):
    """The app's own word on the engine of its pages (the docstring): {engine, default_engine, chromium_state,
    unavailable, webkit_fallbacks}; {engine: `not read`, why} when `debug.cef` gave no state."""
    try:
        reply = rpc("debug.cef", None, 20)
    except Exception as error:  # noqa: BLE001  a word for the report: its fault must not end a launch or lose the rows
        return {"engine": "not read", "why": repr(error)[:200]}
    if not isinstance(reply, dict) or reply.get("error") or "state" not in reply:
        return {"engine": "not read", "why": str(reply)[:200]}
    gone, fell, state, default = reply.get("unavailable"), reply.get("fallback"), reply.get("state"), reply.get("default_engine")
    count = int(fell.get("count") or 0) if isinstance(fell, dict) else 0
    engine = "webkit" if gone or default == "webkit" else "chromium not ready" if state != "ready" else "mixed" if count else "chromium"
    return {"engine": engine, "default_engine": default, "chromium_state": state,
            "unavailable": gone.get("code") if isinstance(gone, dict) else gone, "webkit_fallbacks": count}


def launch(opts, form):
    """One launch of the app in the key form `form`, the act that makes it the active app (`activate`) and its
    preflight: (the app, what the report says of it). Raises PreflightFailed (the app is stopped then; a
    SecondInstance is one) or the launcher's LaunchError."""
    app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out,
                                env={**LAUNCH_ENV, **({"CMUX_NEXT_NO_ACTIVATE": None} if form == "activate" else {})})
    app.launch()
    engine = page_engine(app.rpc)
    print(f"PREFLIGHT page engine: engine={engine['engine']} " + (f"({engine['why']})" if "why" in engine else
          f"default_engine={engine['default_engine']} chromium_state={engine['chromium_state']} "
          f"unavailable={engine['unavailable'] or 'none'} webkit_fallbacks={engine['webkit_fallbacks']}"), flush=True)
    try:
        active = activate(app, form)
        window = place(app) if form == "activate" else "the launcher's"
        link = preflight(app, STRESS.Stress(app.rpc, log=lambda line: None), opts.out, opts.film, form, opts.display)
    except PreflightFailed:
        app.stop()
        raise
    except Exception as error:  # noqa: BLE001  a fault of a preflight call is a failed preflight too
        print(f"PREFLIGHT tool FAILED: {error!r}", flush=True)
        app.stop()
        raise PreflightFailed(f"tool: {error!r}") from error
    return app, {"form": form, "activate": active, "page_engine": engine, "window": window, "display": opts.display,
                 "no_activate": app.launched_env.get("CMUX_NEXT_NO_ACTIVATE") == "1",
                 "display_link": {k: link.get(k) for k in ("frames", "p50_ms", "refresh_ms")}}


def take_bound(opts):
    """The seconds that a take's child process may run: not a tight bound; its job is that the report comes back.
    The take's own waits that have a bound: 2 of --deadline (the app's `done` word, the replies of the keys), 2
    times the keys' own time (the keys, then the wait for their schedule), and about 320 s of fixed bounds (the
    pane's focus 130 s, the bluetoothd start 13 s, the frames 8 s, the end list 25 s, the film's file 20 s, the
    read of the host's log 120 s). The rest (one more --deadline and 100 s) is for the signpost recorder's own
    start and end and for the replies of a big session."""
    return 3 * opts.deadline + 2 * opts.hold_ms / 1000 + 420


def record_take(command, bound):
    """The take's child (the signpost recorder with the take's own command) in a session of its own, `bound` s at
    most: its exit code, or None when it did not end. Then ONE SIGKILL goes to its process group (the recorder, its
    log stream and the take are in it), so that a take on an app that does not answer cannot use the whole step:
    the report must come back."""
    child = subprocess.Popen(command, stdout=subprocess.DEVNULL, start_new_session=True)
    try:
        return child.wait(timeout=bound)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass  # the group ended in this instant
        try:
            child.wait(timeout=TAKE_KILL_S)
        except subprocess.TimeoutExpired:
            pass  # the row and the report still come
        return None


def not_run(scenario, index, form, why):
    """The row of a take that had no key: it is in no number, and the run has a failure for it."""
    return {"scenario": scenario, "round": index, "key_source": form, "not_run": why, "errors": [], "invalid": [f"not run: {why}"]}


def run(opts, app, signposts, report, form):
    builder = STRESS.Stress(app.rpc)
    path, roots = daemon_of(app)
    if not path:
        report["failures"].append("no daemon of the app's bundle with a socket")
        return
    began, have = time.monotonic(), len(STRESS.wait(builder.workspaces, 60) or [])
    asked = max(1, opts.workspaces - have - 1)
    made, code, count, tail = seed(app, asked, opts.live_shells, opts.page_url, opts.seed_deadline, opts.out)
    # The made workspaces are in the app's list before the rows' workspace is made: it is found as the new one.
    listed = STRESS.wait(lambda: len(builder.workspaces()) >= have + count, 120, step=1.0)
    workspace = builder.new_workspace()
    report["session"] = {"asked": opts.workspaces, "maker_exit": code, "maker_last_lines": tail if code else [], "maker_made": count,
                         "maker_asked": made.get("asked"), "before": made.get("before"), "after": made.get("after"),
                         "make_s": made.get("make_seconds"), "seed_s": round(time.monotonic() - began, 1),
                         "listed_by_the_app": len(builder.workspaces()), "all_listed": bool(listed)}
    print("HELD-NEW-TAB-SESSION " + json.dumps(report["session"]), flush=True)
    if code or not listed:
        report["failures"].append(f"the session is not the one asked (maker exit {code}; in the app's list: {bool(listed)})")
    panes = builder.panes(builder.workspace(workspace)) if workspace else []
    if not panes:
        report["failures"].append("the workspace of the rows never appeared with a pane")
        return
    builder.show(workspace)
    pane = panes[0]["id"]
    for _ in range(opts.neighbours):
        builder.add_tab(workspace, pane, "terminal")
    # `no_openers`: why `openers` is None (the words for the `close` row that then has no verdict).
    state, openers, no_openers = BENCH.start_state(builder, workspace), {}, None
    takes = [(r, n) for r in range(opts.rounds) for n in ROWS] + [("wide", "hold")] + ([("film", "mixed")] if opts.film else [])
    for index, name in takes:
        wide = index == "wide"
        # The wider recording has a scenario name of its own: a reader that groups the rows by `scenario` (the bench
        # `newtab` does) then keeps it out of the numbers of `hold` and lists it as a scenario of its own.
        scenario, row, ended = WIDE_NAME if wide else name, None, None
        out = os.path.join(opts.out, f"{index}-{name}")
        ndjson, before, start = os.path.join(out, "run.ndjson"), stats(path), time.time()
        if pane not in {found["id"] for found in builder.panes(builder.workspace(workspace))}:
            row = not_run(scenario, index, form, f"the pane {pane} of the rows is gone")
        else:
            os.makedirs(out, exist_ok=True)
            command = [sys.executable, os.path.join(NEXT, "perf-signposts.py"), "--pid", str(app.process.pid)]
            for category in WIDE_CATEGORIES if wide else ROW_CATEGORIES:
                command += ["--category", category]
            command += ["--save", ndjson, "--allow-loss", "--json", "--", sys.executable, os.path.abspath(__file__), "--row", name,
                        "--socket", app.socket, "--workspace", workspace, "--pane", pane, "--out", out, "--keys", opts.keys,
                        "--launch-form", form,
                        "--keep", str(len(state[pane])), "--hold-ms", str(opts.hold_ms), "--every-ms", str(opts.every_ms),
                        "--repeat-delay-ms", str(opts.repeat_delay_ms), "--repeat-ms", str(opts.repeat_ms), "--deadline", str(opts.deadline)]
            bound = take_bound(opts)
            code = record_take(command + (["--film", os.path.join(opts.film, "frames")] if index == "film" else []), bound)
            try:
                with open(os.path.join(out, "scenario.json")) as f:
                    record = json.load(f)
            except (OSError, ValueError) as error:
                record = {"scenario": name, "errors": [f"no record of the take (exit {code}): {error}"]}
            if code is None:
                # No number from a take that was killed, and no other take: the app does not answer.
                ended = f"the take did not end in {bound:.0f} s: its process group was killed, and the run ends here"
                row = {"scenario": scenario, "round": index, "key_source": form, "errors": [ended], "invalid": []}
            elif record.get("not_run"):
                row = not_run(scenario, index, form, record["not_run"])
        if row is not None:
            # A row that did not run leaves no openers for the next one.
            openers, no_openers = None, f"the row before ({scenario}) was not run"
        else:
            row = BENCH.summarize(signposts, ndjson, record) if os.path.exists(ndjson) else \
                {"scenario": name, "errors": record.get("errors", []) + ["no signpost stream"], "invalid": []}
            row["scenario"] = scenario
            fates = row.get("fates") or {}
            # `close` starts with the openers that `hold` left; each other row starts after a restore by script.
            known = openers if name == "close" else {}
            try:
                row["order"], openers = order_row(record, row.get("press_fates"), known, no_openers)
                verdict = row["order"]["equal"]
                no_openers = None if openers is not None else f"the row before ({scenario}) " + (
                    "was not equal to the model" if verdict is False else f"had no verdict: {row['order'].get('why')}")
            except Exception as error:  # noqa: BLE001  a fault of this field must not lose the row: no verdict, with the fault's words
                row["order"], openers = {"equal": None, "why": f"a fault of the tool: {error!r}"}, None
                no_openers = f"the row before ({scenario}) had a fault of the tool in its order"
            row["order"]["openers_at_start"] = None if known is None else len(known)
            try:
                if row.get("press_fates"):
                    row["first_frame"] = first_frame(signposts, ndjson, record, row["press_fates"])
            except Exception as error:  # noqa: BLE001  a fault of this field must not lose the row, and not the order's verdict
                row["first_frame_error"] = repr(error)
            try:
                if row.get("press_fates"):
                    intervals = read_stream(signposts, ndjson)
                    runs = key_runs(intervals, record)
                    row["slow_keys"] = slow_keys(runs, record, row["press_fates"])
                    if wide:
                        found, own = between(intervals, runs, record, row["press_fates"], form)
                        row["wider_recording"] = {"categories": list(WIDE_CATEGORIES), "key_form": form, "limit": WIDE_LIMIT,
                                                  "slow_keys": found, "own_call_tasks_left_out": own}
            except Exception as error:  # noqa: BLE001  a fault of these fields must not lose the row
                row["slow_keys_error"] = repr(error)
            row.update({"round": index, "key_source": form, **(record.get("take") or {}), "keys_posted": record.get("presses"),
                        "tabs_made": fates.get("created", 0), "tabs_closed": fates.get("closed", 0),
                        "keys_without_effect": (record.get("presses") or 0) - fates.get("created", 0) - fates.get("closed", 0),
                        "daemon_requests": requests_between(before, stats(path)), "daemon_slow": slow_records(roots, start, time.time())})
            # The row is measured: a fault of the 2 acts below must not lose it (it is appended and printed after them).
            try:
                if name != "close" and row["tabs_made"]:
                    row["opens"] = opens_of(((app.rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or [])[-min(OPENINGS, row["tabs_made"]):])
            except Exception as error:  # noqa: BLE001
                row["opens_error"] = repr(error)
            try:
                if name != "hold" or wide:  # `close` is the row that closes what `hold` made
                    state, row["not_restored"], row["tabs_given_back"] = restore(builder, workspace, pane, state)
            except Exception as error:  # noqa: BLE001  a restore that stopped is a restore that left a difference
                row["not_restored"] = [f"the restore stopped: {error!r}"]
        report["rows"].append(row)
        report["failures"] += [f"{index} {name}: {why}" for why in (row.get("errors") or []) + (row.get("invalid") or [])]
        report["failures"] += [f"{index} {name}: not restored: {why}" for why in row.get("not_restored") or []]
        print(f"HELD-NEW-TAB-ROW {index} {name}: " + json.dumps({k: v for k, v in row.items() if k != "press_fates"}), flush=True)
        if ended:
            return
        if name == ROWS[-1] and not any(valid(r) for r in report["rows"] if r.get("round") == index):
            report["failures"].append(f"round {index} has no valid row: the run ends here")
            return


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="a Debug or bench `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/held-new-tab")
    parser.add_argument("--workspaces", type=int, default=60, help="the size of the session")
    parser.add_argument("--live-shells", type=int, default=8, help="terminals of the session that keep a shell; each other one is parked")
    parser.add_argument("--page-url", default="http://127.0.0.1:9/", help="the address of each page tab of the session")
    parser.add_argument("--neighbours", type=int, default=2, help="terminal tabs beside the first one in the rows' pane")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--hold-ms", type=float, default=3000)
    parser.add_argument("--every-ms", type=float, default=500, help="`mixed`: one Cmd-W at each")
    parser.add_argument("--repeat-delay-ms", type=float, default=0, help="a held key's first repeat (0: this host's setting)")
    parser.add_argument("--repeat-ms", type=float, default=0, help="a held key's repeat interval (0: this host's setting)")
    parser.add_argument("--keys", default="app-queue", help="the key source; only app-queue is in this script")
    parser.add_argument("--deadline", type=float, default=60.0, help="seconds after a take's frames for the app to say it is done")
    parser.add_argument("--seed-deadline", type=float, default=900.0, help="seconds for the session's maker")
    parser.add_argument("--film", help="a folder for one more `mixed` take under debug.window_record")
    parser.add_argument("--artifact", help="a .tgz to pack: the report, each take's record and signpost stream, the film's frames")
    parser.add_argument("--launch-form", default="auto", choices=tuple(LAUNCH_FORMS),
                        help="activate: launch without CMUX_NEXT_NO_ACTIVATE (the app takes the keyboard, as a person's does), the keys as "
                             "sequences in the key window; one-key: the launcher's launch, each key-down one call; auto: activate, then one-key")
    parser.add_argument("--display", default="real", help="what the entry script says of the display, for the preflight's first line")
    for internal in ("--row", "--socket", "--workspace", "--pane"):
        parser.add_argument(internal, help=argparse.SUPPRESS)
    parser.add_argument("--keep", type=int, default=0, help=argparse.SUPPRESS)
    opts = parser.parse_args()
    if opts.row:
        return take(opts)
    grant = hid_grant()
    print("HID grant: " + {True: "yes", False: "no", None: "unknown (the check failed)"}[grant], flush=True)
    if opts.keys != "app-queue" or not opts.app or opts.every_ms < 200:
        print(f"held-new-tab: NOT RUN: needs --app, --keys app-queue (asked: {opts.keys}) and --every-ms of 200 or more", flush=True)
        return 3
    os.makedirs(opts.out, exist_ok=True)
    report = {"host": BENCH.load("action_signposts_bench", "action-signposts-bench.py").host_facts(), "hid_grant": grant,
              "hold_ms": opts.hold_ms, "every_ms": opts.every_ms, "mixed_repeat_rule": REPEAT_RULE, "session_limit": SEED_LIMIT,
              "rows": [], "failures": []}
    # No osascript in a step: the launcher leaves the sound as it is and its read of the mute state is a no-op.
    os.environ.update({"BENCH_LAUNCH_AUDIO": "keep", "BENCH_LAUNCH_OSASCRIPT": "/usr/bin/true"})
    forms, app = list(LAUNCH_FORMS[opts.launch_form]), None
    while app is None:
        try:
            app, facts = launch(opts, forms[0])
        except (PreflightFailed, bench_launch.LaunchError) as error:  # each printed its own lines
            why = getattr(error, "reason", None) or str(error)
            if len(forms) > 1 and not isinstance(error, SecondInstance):
                # This launch again in the next form.
                print(f"PREFLIGHT next form: {forms[1]} (the {forms[0]} form failed: {why})", flush=True)
                forms.pop(0)
            elif isinstance(error, PreflightFailed):  # no session, no row, no other launch
                report.update({"launch_form": forms[0], "preflight_failed": why})
                report["failures"].append(f"the preflight failed (launch form {forms[0]}): {why}")
                break
            else:
                print(f"held-new-tab: NOT RUN: the app did not launch: {why}", flush=True)
                return 3
    if app:
        engine = facts.pop("page_engine")
        report.update({"launch_form": forms[0], "key_source": f"{forms[0]}: {KEY_SOURCES[forms[0]]}"})
        report["launch"] = {"ready_s": app.ready_seconds, "limits": app.limits, "executable": os.path.basename(app.binary),
                            "agent_page_mock": "CMUX_NEXT_AGENT_PANE_MOCK" in app.launched_env, **facts,
                            "env": {k: v for k, v in sorted(app.launched_env.items()) if k.startswith(("CMUX_", "ACPMUX_"))}}
        try:
            run(opts, app, BENCH.load("perf_signposts", "perf-signposts.py"), report, forms[0])
        except Exception as error:  # noqa: BLE001  the rows so far still go into the report
            traceback.print_exc()
            report["failures"].append(f"the tool stopped: {error!r}")
        finally:
            after = page_engine(app.rpc)
            report["page_engine"] = {"engine": after["engine"], "at_launch": engine, "after_the_rows": after, "limit": ENGINE_LIMIT}
            app.stop()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("HELD-NEW-TAB " + json.dumps(report), flush=True)
    if opts.artifact:
        try:
            print(f"held-new-tab: artifact {opts.artifact}: {len(pack(opts.out, opts.film, opts.artifact))} files", flush=True)
        except (OSError, tarfile.TarError) as error:
            print(f"held-new-tab: no artifact {opts.artifact}: {error!r}", flush=True)
    # A round with no valid row (and so a run with none) and a failed preflight are a failed step in each case.
    empty = [index for index in range(opts.rounds) if not any(valid(row) for row in report["rows"] if row.get("round") == index)]
    return 0 if not report["failures"] else 1 if empty else 2


if __name__ == "__main__":
    sys.exit(main())
