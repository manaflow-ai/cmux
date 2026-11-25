"""cmd-n-paint-e2e.py --screen: Cmd-T and Cmd-N, one key at a time, as the screen showed it. A report, no judgement.

For each key (`--keys`) and each gap (`--gaps`, ms: 0 = one key with the app idle; N = a second key N ms after a
first one, both in one recording, the gap by the app's own timer), `--runs` recordings. Each one is the app's
`debug.new_tab frame_strip` with `above`: every frame that the window server composited for the display (with the
page's pixels) from before the key to `--duration-ms` after it, at `--scale` (1: a point is a pixel). The numbers
of a recording, and what they do not see: new_surface_frames.py.

The display's rate (`--display-hz`; the entry gives it with `--vdisplay=HZ`, the rate of the display that it
made). A frame's number is a row's time over the display's frame time. With no asked rate the frame time is the
median step of the recording's rows, and the recorder gives its rows at its own pace in the still part of a
recording: a frame with no row directly before the page is then not seen. So each row of a run with no asked rate
is INVALID (`display`; new_surface_frames.py `NO_RATE`), and its line says `not known` for the frames with no row.
Only a finite number above 0 is an asked rate (`asked_rate`): a given `--display-hz` that is none (0, a number below
0, `inf`, `nan`) stops the run at its arguments (`given_rate`). An asked rate that is lower than the display's has
the same fault, and the rows can prove it when the rate is more than about 15 % too low and enough rows come one
after the other at the display's own rate: a row whose rows do not agree
with the asked rate, or do not judge it, is INVALID (`display` too; `rate_fault`), and the line of a row has the
judged number (`rate_share`) when its recording has 9 rows or more and a frame after the key. With an asked rate
the head says the limit of this check in one
sentence (`rate_limit_sentence`), and, when a valid row's number is near the limit, that too
(`rate_margin_sentence`). The rows cannot prove that the asked rate is right: the true rate is the display's own,
which the entry makes.

The session: `--workspaces N` makes the session that many workspaces with the repository's one session maker
(scripts/perf-bench/session_real.py make, as scripts/measure/pane-motion-films.py does): each added workspace
has a terminal tab and a page tab, `--live-shells` of the terminals keep a shell and each other one is parked. No
chat is in that session: a session with chats is not measured by this tool. A launch by the driver (`--app`) starts
from an empty saved session for its tag (`fresh_session`), so the made session is this run's own.

Before each recording a spare New Tab page is ready (a row with none in 30 s is INVALID). A Cmd-T is pressed from
a terminal tab that Control-` opened, as the driver's own openings (the new page then changes the content area);
after the recording its new tabs close, then that terminal tab. A Cmd-N is pressed from the workspace that the
app shows; its new workspaces close after the recording. Each row says the count of tabs or workspaces before its
key.

The proof of the input, in each row: the count of tabs (Cmd-T) or workspaces (Cmd-N) and the opening marks must
each say one opening for each sent key; a row where one does not is INVALID. The app's own opening records are a
fact by kind in the row (`opening_records`; new_surface_frames.py `records_fact`): a Cmd-N that takes the
workspace that the app reserved at idle makes none, and a new tab whose page was not the spare makes two. The
app keeps only its newest opening records (its list has 64 places), so a recording's new ones are counted by the
list's content, not by its length (new_surface_frames.py `opened_since`). That count is right while ONE recording
makes fewer new records than the list has places, so the driver refuses, before its launch, a run in which one
recording can make more than 60 (`openings`: 2 for each New Tab or New Workspace key of a recording). The count of
recordings in a run has no limit. The key goes to the app's key path through `debug.key`'s sender, not
through the keyboard's driver: the path from the keyboard to the app is not in a number.

The window on the screen, and no keyboard. The driver's launch for this mode has `CMUX_NEXT_NO_ACTIVATE=1`, as each
launch of the driver (cmd-n-paint-e2e.py `launch`): the app then takes no keyboard of a person at the Mac, and only
then it reads the 2 variables that place its window (TestWindowPlacement.swift), so the window has the launch's
size on the launch's screen. A key of a recording needs no active app: it goes through `debug.key`'s sender, which
names its window to the app's key path (DebugKey.swift `send`). So `app_active` is a fact of the report and no
condition of a take. What a take needs is the window on the screen. Each run asks ONE time, after the session is
made and before its first tab and its first case: `debug.window.focus {window}` for the first window that the app
lists, with no `activate` (DebugKey.swift `focusWindow`: the app orders that window in front and makes it the key
window of its own windows; the call asks for no activation). Then it reads the app's own answer (`debug.focus`)
and the app's list of windows (`debug.window_list`), up to `ACTIVE_READS` times 0.2 s apart. The list must have ONE
window of the kind `main` (the measured window) that is `visible`, not `miniaturized` and not `occluded`, and with
a launch that placed the window its frame must have the asked width and height (`window_fault`; the tool has no
read of the screen's own frame, so it checks the size and the report keeps x and y). Each other state and an app
that lists no window end the run (`stopped`, the exit code `STOPPED_EXIT`): no tab is made and no case is
recorded. The SAME read comes again after the last case: a window that is then not shown, or whose count, frame or
3 words are not the first read's, makes each row of the take INVALID (`window`), and each case's numbers are made
again. The report's `window` keeps both reads (the frame and the 3 words) and the asked size; it keeps no title
and no word of another app. Limits: the app's `occluded` is AppKit's word for a window of which no part is
visible, so a window that another app covers in part reads as shown (the recorder takes the display with this
app's windows only, WindowFrame+ScreenCaptureKit.swift, so the other app is in no frame); and the 2 reads say
nothing of the time between them.

Each read with a shown window has one of 3 forms (`key_form`). `shell`: the app is active and the measured window
is the key window. `page child`: the app is active, the window names a page as the holder of the keys
(`appkit.child_window_page`), and the list of windows has the key window: a plain child window of the measured
window, of the class that `debug.focus` names as the app's key window. `window shown`: each other state, also an
app that is not active (each launch of the driver). The report's `activation` says the form of the read before
the first case (`form`), the app's answer before the ask (`before`) and the facts of the last read (`at_the_end`:
the form, the shown tab's kind, the page that the window names, the first responder, the count of the app's
windows, the class of the app's key window, what the app's no-activate mode gave back); a stop's text says them
too. Each row says `app_active`, `shell_window_is_key` and `key_window_form` from one read directly before its
recording, and the tool does not ask a second time. A row with no form (the app listed no window) is INVALID
(`form`). Runs with 2 forms are 2 states: no pair has both, and the report's `head` says the run's form and how
many rows have another one. A hold's keys go to the shell window as the key window of an active app, so a run
whose form is not `shell` does not run the hold's rows: each is in the report as INVALID (`hold`, `not_run`) with no
call to the app, and `close.hold.not_run` says why. In a run of the form `shell`, a hold's row whose own read says
an app that is not active or a shell window that is not the key window is INVALID (`active`).

`--key-tabs 6,84`: the count of tabs in the key's workspace before a case, as counts that rise, in one launch.
First the tool shows the first workspace that the session's maker made (`action.run goToWorkspace`, then
`snapshot.get`'s focus says that the app shows it; one that the app does not show in `SHOWN_S` s ends the run): the
workspace of the launch can be a home workspace, which has no row in the sidebar's list. With no made workspace
the keys stay in the launch's workspace and the report says so. Then, for each count, the tool makes tabs beside
the shown tab of the key's pane (so all in one pane) by the app's script actions until the app's own list
(`debug.focus`: each pane of the shown workspace) has that many tabs: a Chromium page (`openBrowser.chromium`,
`--page-url`) while the pages are fewer than half of the tabs, else a terminal (`newSurface`). A tab is made when
the app lists it under an id that is not provisional. Then each case runs one time for that count. The report says
the count that the app HAD, not the count asked: each size (`key_tabs.sizes`: asked, tabs, kinds, panes, added,
fault), each case's name and each row's label by the app's list directly before the case, and each row
`workspace_tabs_before` and `workspace_kinds_before` from the read before its recording (the size and the case's
own tabs). A count that is not the asked one is an INVALID reason of each row of the case, and a count at which
the tool could make no tab ends the run (`stopped`): its cases would be the count before's again. The limit: the larger
count comes second in the same launch, so a difference between the counts is the tabs and also what the first
count's cases left in the app.

The Close Tab key (`--keys` with `w`; its rows: new_surface_frames.py `close_of`). Its cases are `--close-cases`,
not `--gaps`, each from a terminal tab that Control-` opened:
  idle  the key alone. The tool first opens the tab to close, a New Tab page, with one New Tab key, and waits
        1.5 s: no frame of the recording has that opening.
  key   the key `--close-gap-ms` after ONE New Tab key.
  downs the key `--close-gap-ms` after the last of `--hold-keys` New Tab key-downs at a held key's times (the
        second one `--hold-delay-ms` after the first, each next one `--hold-repeat-ms` after the one before), each
        with NO repeat flag. This is not a hold of the key, and the case's name says so.
  hold  the key `--close-gap-ms` after the last key-down of a hold of the New Tab key, at the same times: the
        first key-down, then its repeats WITH the repeat flag.
The recording is frame_strip's with the key `w` alone. The New Tab keys are not the recorder's. In `key` and
`downs` the tool sends each as one `debug.key` call at its time by the tool's own clock, beside the recording's
call (the recorder sends its key 120 ms after its start, so the tool starts the recording that long before the
Close Tab key's time): the app gives such a key to its window directly, with no repeat flag, so the key router's
path for a repeated key is not in these rows. In `hold` the keys are ONE key sequence of `debug.key`
(`{"sequence", "key_window": "shell"}`): the app makes the shell window its key window (it does not activate the
app, and no call of the tool does: a hold's rows run only in a run of the form `shell`), builds each step as an
event with its planned time and posts it to its own event queue (Command down, T down, each repeat of T with the
repeat flag, T up and Command up before the Close Tab key's time), and plays the steps by its own clock from the
call. Limits of `hold`: the Close Tab key itself is the recorder's and not a key of the queue; and the Command
key is up again before it. A sequence that the app refused (the window did not become key) is an INVALID row with
no recording.

The true time between the last New Tab key and the Close Tab key is the app's (`last_new_tab_key_before_ms`, from
the `newTab.open` mark), and the asked time is only the tool's plan (`new_tab_keys_sent_ms`: each key-down's time
by the tool's clock, from the Close Tab key's planned time; for `hold` the time of the sequence's call and each
step's planned time after it). `new_tab_keys_by` says the sender. A row is INVALID when the app did not list the
pane's tabs, when the count of tabs does not say one tab for each New Tab key-down and one tab closed, when the
recording has no `newTab.open` mark before the Close Tab key (the last New Tab key then went in before the
recording's start, or opened nothing) or has one after it, and when the app refused a New Tab key. After the
recording the tool closes what is left of its own tabs, and never more tabs than it opened.

`--page-watch N`: the last N recordings of each case also ask the new page for its own layout watch (`debug.agent_pane
layout_watch`: the page's composer, its chips and its header, each frame of the page): the parts that moved after
the page's first frame, by name, from and to, in points. The ask goes on the app's socket while the frames are
recorded, and it is made again each 33 ms until a page answers: for one key from the recording's start, when no
page may be in the pane yet; for a second key from 30 ms after its due time. Those rows say `page_watch` and the
other rows have none; with the defaults (`--runs 3`, `--page-watch 3`) each row has it. A watch that a page
answered before the judged key says `before_the_key`. A move before the watch's first frame is in the screen's
frames only.

Kept pictures (`--screen-tgz FILE`, with the report): for the first `--keep-keys` recordings of each case and for
each recording with a change after the first content or an INVALID reason, the frame before the key, the named
frames and the first frame of each change, at the recorded scale. No picture of a later recording of a case is
kept after `PICTURES_A_CASE` kept pictures of that case: each case has its own, also the last one of a run.

A recording whose reply is the control's `timeout` with `state: in_progress` (frame_strip's compare and its files
took longer than the call's limit; more frames or a larger `--scale` make it longer) is an INVALID row, and the
app's call goes on after the reply: it uses the processor and the app's one list of bench marks, so a key in that
time has numbers of 2 calls. The app has no call that says when frame_strip ended; its last act is the file
`strip.png` in the recording's folder. So the tool waits for that file (up to `CALL_END_PAUSES` pauses of 0.5 s)
before it removes the folder and sends a key, ends that case (`ended_early` in the case, `call_went_on` in the
row), and goes on with the next case. A call whose file did not come stops the run: no later recording, `stopped`
in the report and in the last printed line, and the driver's exit code is `STOPPED_EXIT`. A call that made no frame
writes no such file and reads as one that did not end. The row's folder is removed before each call, so a file of
an earlier run is not read as this call's.

The app's settings (new_surface_look.py). The driver's launch gives its app an empty config: the app is at the
schema's defaults. `--window-look` (the words of window_look.py) makes the launch write other settings. Each run,
with a look or with none, first asks the app itself and prints `NEW-SURFACE-SCREEN-SETTINGS` lines: each key that
the launch wrote with the app's own answer, each other setting that the app holds, the speed of its motion, and
what its first window shows. An app that does not show the asked look (another value for a key, another picture,
no answer) ends the run there: no session is made, no tab, no case (`stopped`, the exit code `STOPPED_EXIT`). The
report has the lines as `settings`, and its `head` ends with them, after the count of the rows that the recorder
lost in each case (new_surface_frames.py `recorder_lost`).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time

import bench_page_engine
import new_surface_frames as frames_of
import new_surface_look

MAKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench", "session_real.py")
LEAD_MS = 120  # frame_strip sends the key this long after its recording starts (later when the first frame is late)
MARK = "NEW-SURFACE-SCREEN"
OPENINGS_LIMIT = 60  # of ONE recording: the app's list of opening records has 64 places (NewTabSparePool.maximumOpenings)
PICTURES_A_CASE = 40  # no picture of a later recording of a case is kept after this many kept pictures of the case
CLOSE_CASES = ("idle", "key", "downs", "hold")  # the Close Tab key's cases, in the default order (the module doc)
KEY_CODE = {"cmd": 55, "t": 17}  # virtual key codes, for a key sequence's steps
SEQUENCE_LEAD_MS = 2.0  # in a key sequence: from Command down to the first key-down of T
KEYS_BY = {"calls": "one `debug.key` call for each key-down, by the tool's clock: no repeat flag, not the app's event queue",
           "sequence": "one key sequence of `debug.key` in the app's event queue, by the app's clock: the first key-down, then "
                       "repeats with the repeat flag"}
NEW_TAB_KEY = {"key": "t", "modifiers": ["command"]}  # one key-down by `debug.key`: no repeat flag
LAST_FILE = "strip.png"  # the last file that frame_strip writes into its folder (WindowFrame.writeAll), before its reply
CALL_END_PAUSES = 240  # of 0.5 s: how long the tool waits for a frame_strip call that went on after its `timeout` reply
STOPPED_EXIT = 3  # the driver's exit code for a run that stopped before its last case
ACTIVE_READS = 50  # of the app's answer, 0.2 s apart, after the one ask for the window in front (the app's answer can come later)
# The 3 words of the measured window in the app's list of windows (`debug.window_list`), each as a take needs it.
WINDOW_WORDS = (("visible", True), ("miniaturized", False), ("occluded", False))
WINDOW_NOT_SHOWN = "the app's window is not shown as a take needs it (debug.window_list): "
HOLD_NOT_RUN = "hold: a hold needs the key window, this launch gives none"  # a hold's row in a run whose form is not `shell`
PROVISIONAL = "pending_tab_"  # the id of a new tab before the app's daemon named it: no action can name such a tab
MADE_TAB_S = 30.0  # how long the tool waits for a made tab in the app's list
SHOWN_S = 30.0  # how long the tool waits until the app shows the made workspace
KEY_TABS_MIX = ("a Chromium page (`openBrowser.chromium`, `--page-url`) while the pages are fewer than half of the tabs, else a "
                "terminal (`newSurface`); each beside the shown tab of the key's pane, so all in one pane")
KEY_TABS_LIMIT = ("the larger count comes second in the same launch: a difference between the counts is the tabs and also what the "
                  "first count's cases left in the app (caches, the tabs of a hold that closed). Each case's name and each row "
                  "say the tabs that the app listed directly before the case")


def key_tabs(text):
    """`--key-tabs`: counts of tabs that rise, comma separated (argparse's type)."""
    try:
        counts = [int(part) for part in text.split(",")]
    except ValueError:
        counts = []
    if not counts or counts[0] < 1 or any(later <= earlier for earlier, later in zip(counts, counts[1:])):
        raise argparse.ArgumentTypeError(f"{text}: --key-tabs takes counts of tabs that rise, from 1 (6,84)")
    return counts


def window_fact(reply):
    """One read of the app's windows (`debug.window_list`'s answer) as the report keeps it: the count of its windows
    of the kind `main`, and only for an app with ONE such window (the measured window) its `frame` (x, y, width,
    height in screen points) and the 3 words `visible`, `miniaturized` and `occluded`. `key_child`: the class of the
    app's key window when the list says that it is a plain child window of the measured window (its kind is its class:
    no sheet, no popover, no panel), else None. No title and no other field of the answer is kept."""
    entries = [entry for entry in reply.get("windows") or [] if isinstance(entry, dict)] if isinstance(reply, dict) else []
    mains = [entry for entry in entries if entry.get("kind") == "main"]
    fact = {"main_windows": len(mains), "frame": None, "visible": None, "miniaturized": None, "occluded": None, "key_child": None}
    if len(mains) == 1:
        main = mains[0]
        frame = main.get("frame") if isinstance(main.get("frame"), dict) else {}
        fact.update({name: main.get(name) for name, _ in WINDOW_WORDS})
        fact["frame"] = {name: frame.get(name) for name in ("x", "y", "width", "height")}
        fact["key_child"] = next((entry["class"] for entry in entries if entry.get("key") is True and entry.get("class")
                                  and entry.get("kind") == entry.get("class") and main.get("id") is not None
                                  and entry.get("parent") == main.get("id")), None)
    return fact


def window_fault(fact, size=None):
    """(C) the check: why no take runs in the window of one read (`window_fact`), or None: the app has one window of
    the kind `main`, each of the 3 words is as `WINDOW_WORDS` says, and with `size` (`asked_size`) its frame has
    that width and height."""
    if fact["main_windows"] != 1:
        return (f"the app lists {fact['main_windows']} windows of the kind `main` (debug.window_list): the tool names the measured "
                "window only in an app with one")
    wrong = [f"`{name}` is {json.dumps(fact[name], default=str)}" for name, wanted in WINDOW_WORDS if fact[name] is not wanted]
    had = [fact["frame"]["width"], fact["frame"]["height"]]
    if size and had != size:
        width, height = (f"{part:g}" if isinstance(part, (int, float)) else json.dumps(part, default=str) for part in had)
        wrong.append(f"its frame is {width} x {height} points, the launch asked for {size[0]:g} x {size[1]:g}")
    return WINDOW_NOT_SHOWN + ", ".join(wrong) if wrong else None


def asked_size(launched):
    """The width and the height that the driver's launch asked for the app's window (`launched`: its word about its
    launch, None with no launch): the last 2 numbers of `CMUX_NEXT_TEST_WINDOW_FRAME`, which the app reads only with
    `CMUX_NEXT_NO_ACTIVATE=1` (TestWindowPlacement.swift). None for each other launch: the tool then checks no size."""
    env = (launched or {}).get("env") or {}
    if env.get("CMUX_NEXT_NO_ACTIVATE") != "1":
        return None
    try:
        parts = [float(part) for part in str(env.get("CMUX_NEXT_TEST_WINDOW_FRAME") or "").split(",")]
    except ValueError:
        return None
    return parts[2:] if len(parts) == 4 and parts[2] > 0 and parts[3] > 0 else None


def page_named(fact):
    """One read of the app's focus model (`Screen.listing`): the app is active, no cmux window is the key window, and
    the first window names a page as the holder of the keys in a child window (`appkit.child_window_page`). That
    name is the window's record of its focus: it is no proof of the app's key window (`key_form`)."""
    return fact["app_active"] is True and fact["is_key"] is not True and not fact["any_key"] and bool(fact["appkit"].get("child_window_page"))


def key_form(fact, shown):
    """The key window's form of one read of the app's focus model (`fact`: `Screen.listing`) with one read of its
    windows (`shown`: `Screen.window_read`), or None: no such read, a window that is not shown (`window_fault`), or
    an app that lists no window. `shell`: the app is active and its first window is the key window. `page child`:
    the app is active, the first window names a page as the holder of the keys (`page_named`), and the app's list of
    windows has the key window: a plain child window of the measured window, of the class that the focus model names
    as the app's key window. `window shown`: each other state, also an app that is not active: a take needs the
    window on the screen, not the keyboard."""
    if not shown or shown["fault"] or not fact["window"]:
        return None
    if fact["app_active"] is True and fact["is_key"] is True:
        return "shell"
    if page_named(fact) and shown["key_child"] and shown["key_child"] == fact["key_window"]:
        return "page child"
    return "window shown"


def shells(workspace):
    """What the app's list (`snapshot.get`) says of a workspace's terminals: how many, and how many have no shell
    (`dead`: a terminal that the session's maker parked reads so; `parked` itself is the daemon's word and not in
    this list). None when the list has no terminal of it or no such fact."""
    tabs = [tab for screen in workspace.get("screens") or [] if isinstance(screen, dict)
            for pane in screen.get("panes") or [] if isinstance(pane, dict) for tab in pane.get("tabs") or [] if isinstance(tab, dict)]
    terminals = [tab for tab in tabs if tab.get("kind") in ("pty", "terminal")]
    if not terminals or any(not isinstance(tab.get("dead"), bool) for tab in terminals):
        return None
    return {"terminals": len(terminals), "with_no_shell": sum(1 for tab in terminals if tab["dead"])}


def goes_on(reply):
    """True when the control says that the app's call of this reply still runs (`timeout` with `state: in_progress`)."""
    error = reply.get("error")
    data = error.get("data") if isinstance(error, dict) else None
    return isinstance(data, dict) and data.get("state") == "in_progress"


def close_cases(text):
    """`--close-cases`: the Close Tab key's cases by name (argparse's type)."""
    kinds = [kind for kind in text.split(",") if kind]
    unknown = [kind for kind in kinds if kind not in CLOSE_CASES]
    if unknown or not kinds:
        raise argparse.ArgumentTypeError(f"{', '.join(unknown) or 'no case'}: the Close Tab key's cases are {', '.join(CLOSE_CASES)}")
    return ",".join(kinds)


def given_rate(text):
    """`--display-hz`: a finite number above 0 (argparse's type). A given value that is none stops the run at its
    arguments, before a launch and before a case; only a run with no `--display-hz` goes on with no asked rate."""
    try:
        rate = frames_of.asked_rate(float(text))
    except ValueError:
        rate = None
    if rate is None:
        raise argparse.ArgumentTypeError(f"{text}: --display-hz takes a finite number above 0 (with no --display-hz the run goes on and each row is INVALID)")
    return rate


def close_plan(kind, opts):
    """The New Tab key-downs of one Close Tab recording: how long before the Close Tab key's time each one goes
    in, in ms, the first one first. `idle` has none, `key` has one, `downs` and `hold` have `--hold-keys` at a held
    key's times."""
    if kind == "idle":
        return []
    downs = [0.0] if kind == "key" else [0.0] + [opts.hold_delay_ms + opts.hold_repeat_ms * index for index in range(max(0, opts.hold_keys - 1))]
    return [downs[-1] + opts.close_gap_ms - at for at in downs]


def close_case(kind, opts):
    """A Close Tab case's name in the report."""
    if kind == "idle":
        return "cmd-w/idle"
    count = len(close_plan(kind, opts))
    after = {"key": "a New Tab key", "downs": f"{count} New Tab key-downs at a hold's times, no repeat flag"}.get(
        kind, f"a hold of the New Tab key ({count} key-downs: 1 and {count - 1} repeats with the repeat flag)")
    return f"cmd-w/{opts.close_gap_ms:g} ms after {after}"


def hold_steps(plan, gap_ms):
    """A hold of the New Tab key as the steps of one key sequence (`debug.key {"sequence"}`): Command down, T down,
    each repeat of T with the repeat flag at its time of `plan` (close_plan), then T up and Command up, both before
    the Close Tab key's time (`gap_ms` after the last repeat)."""
    steps = [{"key_code": KEY_CODE["cmd"], "down": True}, {"key_code": KEY_CODE["t"], "down": True, "after_ms": SEQUENCE_LEAD_MS}]
    steps += [{"key_code": KEY_CODE["t"], "down": True, "after_ms": before - at, "repeat": True} for before, at in zip(plan, plan[1:])]
    return steps + [{"key_code": KEY_CODE["t"], "down": False, "after_ms": min(40.0, gap_ms * 0.4)},
                    {"key_code": KEY_CODE["cmd"], "down": False, "after_ms": min(5.0, gap_ms * 0.05)}]


def openings(opts):
    """The most opening records that ONE recording of the run can make: 2 for each New Tab or New Workspace key
    that goes in from the read of the app's list before the recording to the read after it."""
    keys = [key for key in opts.keys.split(",") if key]
    most = 0
    if any(key != "w" for key in keys):
        most = max((2 * (2 if float(gap) else 1) for gap in opts.gaps.split(",") if gap), default=0)
    if "w" in keys:
        most = max([most] + [2 * len(close_plan(kind, opts)) for kind in opts.close_cases.split(",") if kind])
    return most


def add_arguments(parser):
    """The mode's own arguments; the driver has `--screen` itself and adds these only with it."""
    parser.add_argument("--close-cases", type=close_cases, default=",".join(CLOSE_CASES),
                        help="--screen with the key w: the Close Tab key's cases, comma separated (idle, key, downs, hold)")
    parser.add_argument("--close-gap-ms", type=float, default=100.0, help="--screen with the key w: ms from the last New Tab key to the Close Tab key")
    parser.add_argument("--hold-keys", type=int, default=6, help="--screen with the key w: the key-downs of the hold of the New Tab key")
    parser.add_argument("--hold-delay-ms", type=float, default=375.0, help="--screen with the key w: ms from a hold's first key-down to its second")
    parser.add_argument("--hold-repeat-ms", type=float, default=90.0, help="--screen with the key w: ms between a hold's later key-downs")
    parser.add_argument("--key-tabs", type=key_tabs, default=[],
                        help="--screen: counts of tabs in the key's workspace before a case, rising (6,84): each case runs at each count")
    parser.add_argument("--window-look", type=new_surface_look.asked, default=None,
                        help="--screen: the settings of the launched app (window_look.py's words: opaque, or KEY=VALUE parts); "
                             "an app that does not show them ends the run before its session")
    parser.add_argument("--gaps", default="0,100", help="--screen: ms between two keys of one recording, comma separated (0: one key)")
    parser.add_argument("--workspaces", type=int, default=0, help="--screen: make the session this many workspaces first (0: as launched)")
    parser.add_argument("--live-shells", type=int, default=8, help="--screen: terminals of the made session that keep a shell")
    parser.add_argument("--page-url", default="http://127.0.0.1:9/", help="--screen: the address of each page tab of the made session")
    parser.add_argument("--seed-deadline", type=float, default=1500.0, help="--screen: seconds for the session's maker")
    parser.add_argument("--scale", type=float, default=1.0, help="--screen: the scale of the recorded frames")
    parser.add_argument("--tolerance", type=float, default=frames_of.TOLERANCE, help="--screen: the share of a region's pixels under which two pictures are one")
    parser.add_argument("--page-watch", type=int, default=3, help="--screen: recordings of each case that also ask the page for its layout watch")
    parser.add_argument("--keep-keys", type=int, default=2, help="--screen: recordings of each case whose pictures are kept in any case")
    parser.add_argument("--screen-tgz", help="--screen: write the report and the kept pictures here")
    parser.add_argument("--display", default="", help="--screen: the display's own line, for the report (the entry's virtual display)")
    parser.add_argument("--display-hz", type=given_rate, default=None,
                        help="--screen: the display's refresh rate, a finite number above 0 (the entry gives it for the display that it made); "
                             "with none each row is INVALID")
    parser.add_argument("--build", help="--screen: the build's form (scripts/measure/build-flags.py's file), for the report")
    parser.add_argument("--page-engine", default="cef", choices=bench_page_engine.WANTED,
                        help="--screen: the engine that the new page must run in for a row to be a number (any: each row only says it)")


def seed(socket_path, count, live, url, deadline, out):
    """`count` more workspaces by session_real.py `make` on the app's daemon (pane-motion-films.py's seed)."""
    command = [sys.executable, MAKER, "make", "--app-socket", socket_path, "--workspaces", str(count), "--terminals", str(count),
               "--agents", "0", "--no-agents", "--settle", "0", "--tabs", str(2 * count), "--panes", str(count),
               "--browser-tabs", str(count), "--browser-url", url, "--live-shells", str(live), "--out", os.path.join(out, "session.json")]
    began = time.monotonic()
    try:
        done = subprocess.run(command, check=False, timeout=deadline, capture_output=True, text=True)
        code, said = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as late:
        parts = [part.decode(errors="replace") if isinstance(part, bytes) else part or "" for part in (late.stdout, late.stderr)]
        code, said = f"not done in {deadline:.0f} s", "".join(parts)
    print(said[-3000:], flush=True)
    counted = re.findall(r"^made (\d+)/", said, re.M)
    return {"asked_more": count, "live_shells": live, "maker_exit": code, "maker_said_made": int(counted[-1]) if counted else 0,
            "seed_s": round(time.monotonic() - began, 1)}


def fresh_session(tag, app=None):
    """An empty saved session for the tag's next launch, as each BenchApp launch has (bench_launch.start_fresh_state:
    a tag's earlier state moves aside). The mode's session of many workspaces is under the entry's one fixed tag, and
    bench_launch.py says that a launch restores its tag's saved session. The state moves only while no process of
    the tag runs: with `app` (its bundle), the tag's daemons that an earlier run left end first (tag_teardown.py),
    because such a daemon keeps its session.

    The teardown ends each process that runs from below the path `app`, and their direct children (the shells of the
    tag's terminals). So this refuses, and ends nothing, when the path is not a `cmux DEV <tag>.app` bundle
    (bench_launch.tag_of: a shipped bundle, a folder that is no bundle), when the bundle's tag is not `tag`, and
    when an app of the bundle runs now (`tag-in-use`, as a BenchApp launch refuses): that app is a person's, or
    another run's, and not this run's to end. A process lists the path that it was started by, so the app is
    searched by the bundle's real path, by the path as given (a link to the bundle) and by the real path with no
    `/private` before it (a Mac's `/tmp` and `/var`). The state that moves is the bundle's tag's (`--tag My-Tag` is
    the tag `my-tag`)."""
    import bench_launch  # only this mode's launch and the entry's cleanup need it
    if app:
        from tag_teardown import TagTeardown
        given, app = os.path.abspath(app).rstrip("/"), os.path.realpath(app).rstrip("/")
        of_bundle = bench_launch.tag_of(app)  # stops here when the path is not a tagged DEV bundle
        if of_bundle != re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-"):
            sys.exit(f"{MARK}: --tag {tag} is not the tag of {os.path.basename(app)} ({of_bundle}): nothing ended, no session moved")
        paths = {app, given, app[len("/private"):] if app.startswith("/private/") else app}
        running = sorted({pid for path in paths for pid in bench_launch.bundle_pids(path, "Contents/MacOS/")})
        if running:
            sys.exit(f"{MARK}: tag-in-use: an app of {app} runs now (pid {', '.join(map(str, running))}): it is not this "
                     "run's to end. Quit it, then run again. Nothing ended, no session moved")
        TagTeardown(app).end()
        tag = of_bundle
    bench_launch.start_fresh_state(tag)


def holes(row):
    """The end of a row's printed line: the frames with no row from the key to its first frame, how early that
    frame can be, the second key's own first frame of a recording of two keys, and the app's opening records.
    An INVALID row's line so still says how wrong its first frame can be. A row with a `display` reason (no asked
    display rate, or an asked rate that the rows do not prove) says `not known` for each of these counts, and why:
    its frame time does not see such a frame."""
    span, second, records = row.get("first_frame_span"), row.get("second_first"), row.get("opening_records")
    blind = frames_of.rate_not_known(row.get("invalid"))
    said = "" if not span else f" no_row_to_content_first=not known early_ms_at_most=not known ({blind})" if blind else (
        f" no_row_to_content_first={span['no_row']}/{span['frames']} longest_gap_ms={span['longest_gap_ms']:g} "
        f"early_ms_at_most={span['early_ms_at_most']:g}"
        + (f" partial state: not seen in {span['no_row']} frames" if span["no_row"] else ""))
    if row.get("gap_ms") and "second_first" in row:
        said += " second_first=" + ("none" if not second else (
            f"{json.dumps([second['frame'], second['ms']])} after_mark_ms={second['after_mark_ms']:g} "
            + ("second_no_row=not known second_early_ms_at_most=not known" if blind else (
                f"second_no_row={second['span']['no_row']}/{second['span']['frames']} "
                f"second_early_ms_at_most={second['span']['early_ms_at_most']:g}"
                + (f" second key's partial state: not seen in {second['span']['no_row']} frames" if second["span"]["no_row"] else "")))
            + f" moving_at_the_mark={second['moving_at_the_mark']}"))
    return said + ("" if not records else f" records={json.dumps(records['spare'])}") + close_said(row)


def close_said(row):
    """The end of a Close Tab row's printed line: which tab closed, which tab shows, and the close's frames. A row
    with a `display` reason says `not known` for the order, and why: the order is a count of frames, and the row's
    frame time does not see a frame with no row (the row's `close_tab.order` in the JSON stays as the reader made it)."""
    fact = row.get("close_tab")
    if not fact:
        return ""
    blind = frames_of.rate_not_known(row.get("invalid"))
    order = f"not known ({blind})" if blind else fact["order"]

    def at(name):
        return json.dumps(fact.get(name) and [fact[name]["frame"], fact[name]["ms"]])
    keys = "" if not fact["new_tab_keys"] else (f" new_tab_marks_before_ms={json.dumps(fact['new_tab_marks_before_ms'])} "
                                                f"new_tab_keys_sent_ms={json.dumps(fact.get('new_tab_keys_sent_ms'))}")
    # Frames with no row directly before the strip's first change: `strip_first` is then the latest frame of it.
    earlier = fact.get("strip_first_can_be_frames_earlier")
    return (f" closed={fact.get('closed_is')!r} shows={(fact.get('shown_after') or {}).get('is')!r} content_gone={at('content_gone')} "
            f"shown={at('content_shown')} strip_first={at('strip_first')}"
            + (f" strip_first_can_be_frames_earlier={earlier}" if earlier else "")
            + f" between={fact.get('content_between_frames')} "
            f"blank={fact.get('blank_frames')}{keys} order={order!r}")


def beside(work):
    """Starts `work` in a thread beside the caller (the sender of a Close Tab recording's New Tab keys). Returns
    the call that waits for its end."""
    runner = threading.Thread(target=work, daemon=True)
    runner.start()
    return lambda: runner.join(timeout=60)


class Screen:
    """One run of the mode on a running app. `rpc(method, params, timeout)` is the driver's; `tools` are its own
    steps (`spare_ready`, `terminal_tab`, `close_new`), and `sleep` its pause. `clock` (seconds) times the keys of
    a Close Tab recording, and `start` runs their sender (`beside`: a thread)."""

    def __init__(self, opts, rpc, tools, sleep=time.sleep, make_session=seed, clock=time.monotonic, start=beside):
        self.opts, self.rpc, self.tools, self.sleep, self.make_session = opts, rpc, tools, sleep, make_session
        self.clock, self.start = clock, start
        self.keep = os.path.join(opts.out, "screen-keep")
        self.rows, self.kept, self.kept_in_case = [], 0, 0
        # The driver's word about its launch (run_end_record.py): a text makes each row INVALID. `launch`: its facts.
        # `launched`: the launch's environment and the bundle's CLI (new_surface_look.py `cli_try`), None with no launch.
        self.launch_fault, self.launch, self.launched = None, None, None
        # A run with no asked display rate: this reason is in each row that has a recording (the module doc).
        self.rate = frames_of.asked_rate(opts.display_hz)
        self.display_fault = None if self.rate else frames_of.NO_RATE
        # `made`: the workspaces that the session's maker made. `size`, `tag`: with `--key-tabs`, the count in work
        # (asked and had) and its part of a row's label. `activation`, `key_workspace`: the report's facts of both.
        self.made, self.size, self.tag, self.activation, self.key_workspace = [], None, "", None, None
        # `window_facts`: the report's `window` (the read of the app's windows before the first case and after the last one).
        self.window_facts = None

    def topology(self):
        snap = self.rpc("snapshot.get", None, 180) or {}
        return (snap.get("topology") or snap) if isinstance(snap, dict) else {}

    def listed(self):
        return [w for w in self.topology().get("workspaces") or [] if isinstance(w, dict)]

    def workspaces(self):
        return len(self.listed())

    def count(self, key):
        """What one more opening adds one to: the focused pane's tabs (Cmd-T), the workspaces (Cmd-N)."""
        if key == "n":
            return self.workspaces()
        return len((self.rpc("debug.new_tab", {"action": "switch_and_type"}, 30) or {}).get("tabs") or [])

    def opened(self):
        return (self.rpc("debug.new_tab", {"action": "state"}, 30) or {}).get("openings") or []

    def session(self):
        opts, before = self.opts, self.listed()
        have = len(before)
        fact = {"asked": opts.workspaces, "at_launch": have, "chats": 0}
        if opts.workspaces > have:
            fact.update(self.make_session(opts.socket, opts.workspaces - have, opts.live_shells, opts.page_url, opts.seed_deadline, opts.out))
        after, known = self.listed(), {w.get("id") for w in before}
        self.made = [w for w in after if w.get("id") and w.get("id") not in known]
        fact["listed_by_the_app"] = len(after)
        fact["as_asked"] = not opts.workspaces or fact["listed_by_the_app"] == opts.workspaces
        print(f"{MARK}-SESSION {json.dumps(fact)}", flush=True)
        return fact

    def watch(self, out, start_at, stop_at):
        """Asks the shown page for its layout watch from `start_at` until one answers (before the key the pane shows
        a terminal, so the ask fails at once and is asked again), as chat-open-bench.py's click cases do."""
        while time.monotonic() < start_at:
            self.sleep(0.005)  # tool pacing: the second key of a gap recording is not sent yet
        while time.monotonic() < stop_at:
            asked = time.monotonic()
            reply = self.rpc("debug.agent_pane", {"action": "layout_watch", "ms": max(100, self.opts.duration_ms - 200)},
                             self.opts.duration_ms / 1000 + 8)
            if isinstance(reply, dict) and not reply.get("error") and "frames" in reply:
                out["watch"], out["asked"] = reply, asked
                return
            out["error"] = json.dumps(reply, default=str)[:300]
            self.sleep(0.033)  # tool pacing: no page is in the pane yet

    def one(self, key, gap, run, session_fault):
        opts, label = self.opts, f"cmd-{key}-{'idle' if not gap else f'gap{gap:g}'}{self.tag}-{run}"
        keys_sent = 2 if gap else 1
        row = {"label": label, "key": key, "gap_ms": gap, "run": run, "invalid": []}
        # Cmd-T from a terminal tab (Control-`), as the driver's openings: the new page then changes the content area.
        own_tabs = self.count("t") if key == "t" else None
        if key == "t":
            self.tools["terminal_tab"]()
        deadline = time.monotonic() + 30
        while not self.tools["spare_ready"]():
            if time.monotonic() > deadline:
                row["invalid"].append("spare: no ready spare page in 30 s before the key")
                self.close(0, own_tabs)
                return row
            self.sleep(0.2)  # tool pacing, as the driver's own wait for a ready spare
        before_count, before_opened = self.count(key), self.opened()
        row["tabs_before" if key == "t" else "workspaces_before"] = before_count
        self.before(row)
        self.sleep(0.5)  # the window settles (caret, hover) before the recording, as the driver's warm openings
        folder = os.path.join(opts.out, label)
        # `capture`: the screen's frames also where the app has the Screen Recording grant (frame_strip then takes
        # the window list by itself, and the page is not in those frames).
        params = {"action": "frame_strip", "key": key, "dir": folder, "above": True, "capture": frames_of.CAPTURE,
                  "scale": opts.scale, "tolerance": opts.tolerance, "duration_ms": opts.duration_ms + gap}
        if gap:
            params.update({"repeat": 2, "repeat_interval_ms": gap})
        # No file of an earlier run in the row's folder (`--out` has a fixed default): an old last file is no call's end.
        shutil.rmtree(folder, ignore_errors=True)
        watched, watcher = {}, None
        asked = time.monotonic()
        if run >= opts.runs - opts.page_watch:
            watcher = threading.Thread(target=self.watch, daemon=True,
                                       args=(watched, asked + (LEAD_MS + gap + 30) / 1000 if gap else asked, asked + opts.duration_ms / 1000 + 6))
            watcher.start()
        reply = self.rpc("debug.new_tab", params, (opts.duration_ms + gap) / 1000 + 180) or {}
        if watcher:
            watcher.join(timeout=max(0.0, asked + opts.duration_ms / 1000 + 6 - time.monotonic()) + 20)
        if "error" in reply:
            row["invalid"].append(f"frame_strip: {json.dumps(reply.get('error'), default=str)[:300]}")
            if goes_on(reply):
                row["call_went_on"] = self.call_end(folder)
            shutil.rmtree(folder, ignore_errors=True)
            # Cmd-W only for what the keys opened: a call that the app refused sent no key, and a thing that another
            # actor opened in the wait is not the tool's (never more Cmd-W than keys).
            self.close(min(keys_sent, max(0, self.count(key) - before_count)), own_tabs)
            return row
        records = self.opened()
        row.update(frames_of.one_key(reply, key, gap, opts.tolerance, self.rate))
        row["label"] = label
        opened = frames_of.opened_since(before_opened, records)
        faults, starts = frames_of.input_proof(key, keys_sent, opened, self.count(key) - before_count, reply.get("spans"))
        row["invalid"] += faults + [fault for fault in (self.display_fault, session_fault, self.launch_fault) if fault]
        # The marks' times from the row's zero (the reply's own zero is `key_work_ms` after it).
        starts = [round(start + (row.get("key_work_ms") or 0), 1) for start in starts]
        spare = [bool(record.get("spare")) for record in records[len(records) - opened:]]
        row.update({"keys_sent": keys_sent, "opening_marks_ms": starts, "lead_ms": reply.get("lead_ms"),
                    "second_key_late_ms": round(starts[1] - gap, 1) if gap and len(starts) > 1 else None,
                    "spare": spare, "opening_records": frames_of.records_fact(key, keys_sent, spare),
                    "frame_count": reply.get("frame_count"), "mean_interval_ms": reply.get("mean_interval_ms")})
        # Each measure says its engine: the new page's, read after the recording. A page in another engine is no number.
        row["page_engine"] = bench_page_engine.page_engine(self.rpc("debug.agent_pane", {"action": "engine"}, 20))
        if opts.page_engine != "any" and bench_page_engine.family(row["page_engine"]) != opts.page_engine:
            row["invalid"].append(f"engine: the page ran in {row['page_engine']}, {opts.page_engine} was asked")
        if watcher:
            judged = asked + ((reply.get("lead_ms") if isinstance(reply.get("lead_ms"), (int, float)) else LEAD_MS) + gap) / 1000
            watch = watched.get("watch")
            row["page_watch"] = {"error": watched.get("error") or "no answer"} if not watch else {
                "asked_ms": round((watched["asked"] - judged) * 1000), "frames": watch.get("frames"),
                "first_content_ms": watch.get("first_content_ms"), "elements": watch.get("elements"),
                "shifts": watch.get("shifts"), "appeared": watch.get("appeared"), "scroll_jumps": watch.get("scroll_jumps"),
                # A watch that was asked before the judged key reads the page of the key before it.
                "before_the_key": watched["asked"] < judged}
        self.pictures(row, folder, run)
        shutil.rmtree(folder, ignore_errors=True)
        self.close(keys_sent, own_tabs)
        return row

    def listing(self):
        """One read of the app's focus model (`debug.focus`), for its first window: `window` (its id) and `is_key`,
        `app_active`, the shown workspace's `panes`, `tabs` and `kinds` (counts over each pane; None when the app
        lists no pane), and `pane`: the tabs in order (`{id, kind}`) and the shown tab of the pane that the model
        names, or of the only pane (None when the app lists none). For the key window's form (`key_form`) and the
        report: `windows` (the count of the app's windows in the answer), `any_key` (one of them is the key window),
        the first window's `appkit` part, the class of the app's key window (`key_window`) and what the app says of
        the keyboard that its no-activate mode gave back (`given_back`)."""
        reply = self.rpc("debug.focus", None, 30)
        reply = reply if isinstance(reply, dict) else {}
        windows = [window for window in reply.get("windows") or [] if isinstance(window, dict)]
        fact = {"window": None, "is_key": None, "app_active": reply.get("app_active"), "panes": None, "tabs": None, "kinds": None,
                "pane": None, "error": reply.get("error"), "windows": len(windows),
                "any_key": any(window.get("is_key") is True for window in windows), "appkit": {},
                "key_window": reply.get("key_window"), "given_back": reply.get("keyboard_given_back")}

        def tabs_of(pane):
            return [dict(zip(("id", "kind"), str(tab).rsplit(":", 1) + [None])) for tab in pane.get("tabs") or []]
        for window in windows[:1]:
            panes = [pane for pane in window.get("topology") or [] if isinstance(pane, dict)]
            named = (window.get("model") or {}).get("pane")
            found = next((pane for pane in panes if pane.get("pane") == named), panes[0] if len(panes) == 1 else None)
            fact.update({"window": window.get("id"), "is_key": window.get("is_key"),
                         "appkit": window.get("appkit") if isinstance(window.get("appkit"), dict) else {}})
            if panes:
                kinds = {}
                for tab in [tab for pane in panes for tab in tabs_of(pane)]:
                    kinds[tab["kind"]] = kinds.get(tab["kind"], 0) + 1
                fact.update({"panes": len(panes), "tabs": sum(kinds.values()), "kinds": kinds})
            if found and found.get("tabs"):
                fact["pane"] = {"tabs": tabs_of(found), "selected": found.get("selected")}
        return fact

    def pane(self):
        """The focused pane's tabs in order and its shown tab (`listing`); None when the app lists none."""
        return self.listing()["pane"]

    def window_read(self):
        """One read of the app's windows (`debug.window_list`): `window_fact`'s facts, and `fault`: why no take runs
        in that window (`window_fault`, with the size that the launch asked), or None."""
        fact = window_fact(self.rpc("debug.window_list", None, 30))
        fact["fault"] = window_fault(fact, asked_size(self.launched))
        return fact

    def before(self, row, hold=None):
        """The app's own answer directly before a recording, from one read, into `row`: whether the app is active and
        its window the key window, and with `--key-tabs` the shown workspace's tabs. `hold`: a hold's list of INVALID
        reasons, which gets one when a fact is not true. Returns the focused pane (`pane`)."""
        fact = self.listing()
        # `key_window_form`: the form of the key window in this read (`key_form`); rows of 2 forms are 2 states. The
        # windows are those of the read before the first case; a row whose window names a page reads them again,
        # because that form needs the key window of this read.
        shown = self.window_read() if page_named(fact) else (self.window_facts or {}).get("before_the_first_case")
        row.update({"app_active": fact["app_active"], "shell_window_is_key": fact["is_key"], "key_window_form": key_form(fact, shown)})
        if row["key_window_form"] is None:
            # A row with no form is INVALID (`run` adds the reason: a recording's own facts replace a row's reasons).
            row["no_form"] = ("the app listed no window (debug.focus)" if not fact["window"] else
                              (shown or {}).get("fault") or "the tool had no read of the app's windows")
        if self.size is not None:
            row.update({"workspace_tabs_before": fact["tabs"], "workspace_kinds_before": fact["kinds"]})
        if hold is not None and not (fact["app_active"] is True and fact["is_key"] is True):
            hold.append(f"active: directly before the recording the app says app_active={json.dumps(fact['app_active'])} and its window "
                        f"says is_key={json.dumps(fact['is_key'])}: a hold's keys go to the key window of an active app")
        return fact["pane"]

    def shown(self):
        """The id of the workspace that the app shows (`snapshot.get`'s focus)."""
        return (self.topology().get("focus") or {}).get("workspace")

    def place(self):
        """With `--key-tabs`: shows the first workspace that the session's maker made, and waits until the app says
        that it shows it. Returns the reason that ends the run (the app does not show it), or None."""
        if not self.opts.key_tabs or not self.made:
            why = "the tool asked for no other" if not self.opts.key_tabs else "no workspace was made"
            self.key_workspace = {"is": f"the workspace that the app showed at its launch ({why})"}
            return None
        made = self.made[0]
        name = made.get("name") or made.get("title") or made["id"]
        reply = self.rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": made["id"]}, "focus": True, "origin": "script"}, 120)
        deadline = self.clock() + SHOWN_S
        while (shown := self.shown()) != made["id"] and self.clock() < deadline:
            self.sleep(0.5)  # tool pacing: the app shows the workspace
        # `terminals_before_shown`: by the app's list directly after the maker, before this ask to show the workspace.
        self.key_workspace = {"is": "a workspace of the made session", "id": made["id"], "name": name, "shown_by_the_app": shown == made["id"],
                              "by": "action.run goToWorkspace, then snapshot.get's focus", "terminals_before_shown": shells(made)}
        if shown != made["id"]:
            return (f"the key's workspace: the app does not show the made workspace `{name}` {SHOWN_S:g} s after action.run goToWorkspace "
                    f"(it shows {shown}; the action's reply: {json.dumps(reply, default=str)[:200]}): no tab made, no case recorded")
        self.sleep(2.0)  # tool pacing: the shown workspace's tabs mount before the ask and the first made tab
        return None

    def key_facts(self, fact, shown):
        """(R) the report: what one read of the app says of the keys: the key window's form (`key_form`), the kind of
        the shown tab of the key's pane, the page that the window names as the holder of the keys, the window's
        first responder, the count of the app's windows, the class of the app's key window, and what the app's
        no-activate mode gave back. Each is the app's own word of itself: no word of another app is read."""
        pane = fact["pane"] or {}
        return {"key_window_form": key_form(fact, shown),
                "shown_tab_kind": next((tab["kind"] for tab in pane.get("tabs") or [] if tab["id"] == pane.get("selected")), None),
                "child_window_page": fact["appkit"].get("child_window_page"), "first_responder": fact["appkit"].get("first_responder"),
                "app_windows": fact["windows"], "app_key_window": fact["key_window"], "keyboard_given_back": fact["given_back"]}

    def ask(self):
        """The run's one ask for the window in front, with no activation, and the read of the app's windows before
        the first case (the module doc). Returns the reason that ends the run (no window, a window that the app does
        not show as a take needs it: `window_fault`), or None."""
        fact = self.listing()
        # `before`: the app's answer before the ask (an app that the system made active itself says so here).
        self.activation = {"by": "debug.window.focus", "asked": None, "reply": None, "app_active": fact["app_active"],
                           "shell_window_is_key": fact["is_key"], "reads": 0, "form": None,
                           "before": {"app_active": fact["app_active"], "shell_window_is_key": fact["is_key"]}}
        if not fact["window"]:
            said = f"the app's debug.focus said {json.dumps(fact['error'], default=str)[:200]}" if fact["error"] else "the app lists no window (debug.focus)"
            return f"active: {said}: no tab made, no case recorded"
        # No `activate`: the app orders the window in front and takes no keyboard for it (DebugKey.swift `focusWindow`).
        asked = {"window": fact["window"]}
        reply, began = self.rpc("debug.window.focus", asked, 30), self.clock()
        for reads in range(1, ACTIVE_READS + 1):
            # `at`: the clock at the app's answer, before the read of its windows (`seconds` has no time of that read).
            fact, at = self.listing(), self.clock()
            shown = self.window_read()
            if key_form(fact, shown) or reads == ACTIVE_READS:  # (C) the check
                break
            self.sleep(0.2)  # tool pacing: the app's answer can come later than the call's reply
        # `seconds`: from the ask's reply to the last read of the app's answer (the one with a form, or the last one).
        # (R) `form`: the form of that read (None at a stop); `at_the_end`: its facts.
        end = self.key_facts(fact, shown)
        self.activation.update({"asked": asked, "reply": reply, "app_active": fact["app_active"], "shell_window_is_key": fact["is_key"],
                                "reads": reads, "seconds": round(at - began, 1), "form": end["key_window_form"], "at_the_end": end})
        self.window_facts = {"asked_size": asked_size(self.launched), "before_the_first_case": shown, "after_the_last_case": None, "same": None}
        if end["key_window_form"]:
            return None

        def word(name):
            return json.dumps(end[name], default=str)[:120]
        return (f"window: after debug.window.focus {json.dumps(asked)} {shown['fault'] or 'the app lists no window (debug.focus)'} "
                f"({reads} reads of the app's answer, 0.2 s apart; the call's reply: {json.dumps(reply, default=str)[:300]}; at the stop: "
                f"app_active={json.dumps(fact['app_active'])}, is_key={json.dumps(fact['is_key'])}, shown tab {end['shown_tab_kind']}, "
                f"child_window_page {word('child_window_page')}, first responder {word('first_responder')}, {end['app_windows']} of the "
                f"app's windows listed, the app's key window {word('app_key_window')}, keyboard given back {word('keyboard_given_back')}): "
                "no tab made, no case recorded")

    def hold_off(self):
        """Why the run does not run a hold's rows, or None: a hold's key sequence goes to the shell window as the key
        window of an active app (the form `shell` of the read before the first case)."""
        form = (self.activation or {}).get("form")
        return None if form == "shell" else f"{HOLD_NOT_RUN} (the run's key window form: {form}): not run, no recording"

    def after(self, report, taken):
        """The read of the app's windows after the last case (`taken`: each case's name, rows and size). A window
        that is not shown, or that is not the one of the read before the first case (the count, the frame, the 3
        words), makes each row of the take INVALID, and each case's numbers are made and printed again."""
        first, last = self.window_facts["before_the_first_case"], self.window_read()
        same = not last["fault"] and all(last[name] == first[name] for name in ("main_windows", "frame", "visible", "miniaturized", "occluded"))
        self.window_facts.update({"after_the_last_case": last, "same": same})
        if same:
            return
        why = last["fault"] or "its frame or one of its 3 words is not the one of the read before the first case"
        reason = f"window: the read after the last case: {why}: no row of the take says what the screen showed"
        print(f"{MARK} WINDOW NOT THE SAME {reason}", flush=True)
        for row in self.rows:
            row["invalid"].append(reason)
        for case, rows, size in taken:
            early = report["cases"][case].get("ended_early")
            report["cases"][case] = fact = self.case_fact(rows, size)
            if early:
                fact["ended_early"] = early
            close = frames_of.close_cell(fact["close"]) if "close" in fact else ""
            print(f"{MARK} {case}: {frames_of.cell(fact)}{close}{' (THE CASE ENDED EARLY ' + early + ')' if early else ''} "
                  "(AGAIN, after the read of the window after the last case)", flush=True)

    def case_fact(self, rows, size):
        """One case's part of the report, from its rows (`size`: the `--key-tabs` count in work at the case, or None)."""
        fact = frames_of.summarize(rows)
        fact["active"] = {name: {"yes": sum(1 for row in rows if row.get(name) is True), "of": len(rows)}
                          for name in ("app_active", "shell_window_is_key")}
        forms = [str(row.get("key_window_form")) for row in rows if "key_window_form" in row]
        fact["key_window_forms"] = {form: forms.count(form) for form in sorted(set(forms))}
        fact["recorder_lost"] = frames_of.recorder_lost(rows)
        if size:
            counts = [row["workspace_tabs_before"] for row in rows if isinstance(row.get("workspace_tabs_before"), int)]
            fact["key_tabs"] = {"asked": size["asked"], "had": size["had"],
                                "workspace_tabs_before": {"min": min(counts), "max": max(counts)} if counts else None}
        if rows and rows[0].get("key") == "w":
            fact["close"] = frames_of.close_summary(rows)
        return fact

    def fill(self, asked):
        """`--key-tabs`: makes tabs beside the shown tab of the key's pane until the app lists `asked` tabs in the
        shown workspace (the module doc). Returns the size as the app lists it, with the fault that ended the making."""
        added, fault, fact = {"page": 0, "terminal": 0}, None, self.listing()
        while not fault and fact["tabs"] is not None and fact["tabs"] < asked:
            pane = fact["pane"] or {}
            beside = str(pane.get("selected") or "")
            if not beside or beside.startswith(PROVISIONAL):
                fault = "the app names no shown tab of the key's pane to make a tab beside"
                break
            page = fact["kinds"].get("browser", 0) < (fact["tabs"] + 1) // 2
            name, args = ("openBrowser.chromium", {"url": self.opts.page_url}) if page else ("newSurface", {})
            reply = self.rpc("action.run", {"action": name, "args": args, "focus": True, "origin": "script", "target": f"tab:{beside}"}, 120)
            if isinstance(reply, dict) and reply.get("error"):
                fault = f"the app refused {name}: {json.dumps(reply['error'], default=str)[:200]}"
                break
            had, deadline = {tab["id"] for tab in pane["tabs"]}, self.clock() + MADE_TAB_S
            while True:
                fact = self.listing()
                if any(tab["id"] not in had and not tab["id"].startswith(PROVISIONAL) for tab in (fact["pane"] or {}).get("tabs") or []):
                    added["page" if page else "terminal"] += 1
                    break
                if self.clock() > deadline:
                    fault = f"no new tab in the app's list {MADE_TAB_S:g} s after {name}"
                    break
                self.sleep(0.1)  # tool pacing: the app lists the made tab
        if fact["tabs"] is None:
            fault = fault or "the app lists no pane of the shown workspace (debug.focus)"
        size = {"asked": asked, "tabs": fact["tabs"], "kinds": fact["kinds"], "panes": fact["panes"], "added": added, "fault": fault}
        print(f"{MARK}-KEY-TABS {json.dumps(size)}", flush=True)
        return size

    def until(self, at):
        """Tool pacing: waits until the clock says `at`, in steps of 2 ms at most."""
        while (left := at - self.clock()) > 0:
            self.sleep(min(left, 0.002))

    def close_own(self, own_tabs, most):
        """Closes the tabs that the pane has more than `own_tabs`, and never more than the `most` that the tool opened."""
        count = min(most, max(0, self.count("t") - own_tabs))
        if count:
            self.tools["close_new"](count)

    def close_one(self, kind, run, session_fault):
        """One recording of the Close Tab key (the module doc): `kind` is its case."""
        opts, plan = self.opts, close_plan(kind, self.opts)
        label = f"cmd-w-{'idle' if kind == 'idle' else f'{kind}{opts.close_gap_ms:g}'}{self.tag}-{run}"
        row = {"label": label, "key": "w", "gap_ms": 0, "case": kind, "run": run, "invalid": []}
        off = self.hold_off() if kind == "hold" else None
        if off:
            # Not run: no call to the app, no tab, no recording. The row is in the report with its reason.
            row.update({"invalid": [off], "not_run": True})
            return row
        own_tabs, early = self.count("t"), []
        self.tools["terminal_tab"]()
        deadline = self.clock() + 30
        while not self.tools["spare_ready"]():
            if self.clock() > deadline:
                row["invalid"].append("spare: no ready spare page in 30 s before the keys")
                self.close_own(own_tabs, 1)
                return row
            self.sleep(0.2)  # tool pacing, as the driver's own wait for a ready spare
        engine = None
        if kind == "idle":
            # The tab that the key closes: a New Tab page from one New Tab key, whole before the recording starts.
            opened = self.rpc("debug.key", dict(NEW_TAB_KEY), 30)
            if not isinstance(opened, dict) or opened.get("error"):
                early.append(f"input: the app refused the New Tab key that opens the tab to close: {json.dumps(opened, default=str)[:200]}")
            self.sleep(1.0)  # tool pacing: the page shows, and its opening is in no frame of the recording
            engine = bench_page_engine.page_engine(self.rpc("debug.agent_pane", {"action": "engine"}, 20))
            if opts.page_engine != "any" and bench_page_engine.family(engine) != opts.page_engine:
                early.append(f"engine: the closed tab's page ran in {engine}, {opts.page_engine} was asked")
        # In a hold's row an app that is not active, or a window that is not the key window, is an INVALID reason.
        before, before_opened = self.before(row, early if kind == "hold" else None), self.opened()
        row["tabs_before"] = len(before["tabs"]) if before else self.count("t")
        self.sleep(0.5)  # the window settles (caret, hover) before the recording, as before an opening's
        folder = os.path.join(opts.out, label)
        params = {"action": "frame_strip", "key": "w", "dir": folder, "above": True, "capture": frames_of.CAPTURE,
                  "scale": opts.scale, "tolerance": opts.tolerance, "duration_ms": opts.duration_ms}
        shutil.rmtree(folder, ignore_errors=True)
        # The Close Tab key's planned time: the recorder sends it LEAD_MS after the recording's start. Each New Tab
        # key-down goes in at its own time before it, by one call each, beside the recording's call.
        sent, refused, sequence = [], [], None
        lead = plan[0] + SEQUENCE_LEAD_MS if kind == "hold" else 0.0  # a sequence's call: this long before the Close Tab key
        due = self.clock() + max(plan + [LEAD_MS, lead]) / 1000 + 0.05

        def sender():
            for index, offset in enumerate(plan):
                self.until(due - offset / 1000)
                at = self.clock()
                reply = self.rpc("debug.key", dict(NEW_TAB_KEY), 30)
                sent.append(round((at - due) * 1000, 1))
                if not isinstance(reply, dict) or reply.get("error"):
                    refused.append(index + 1)

        ended = lambda: None  # noqa: E731
        if kind == "hold":
            # The hold: one sequence, which the app plays by its own clock from this call. The call returns at once.
            self.until(due - lead / 1000)
            at = self.clock()
            reply = self.rpc("debug.key", {"sequence": hold_steps(plan, opts.close_gap_ms), "key_window": "shell"}, 30)
            if not isinstance(reply, dict) or reply.get("error"):
                error = reply.get("error") if isinstance(reply, dict) else reply
                row["invalid"] += early + [f"input: the app refused the hold's key sequence: {json.dumps(error, default=str)[:300]}"]
                self.close_own(own_tabs, 1)
                return row
            sequence = {"scheduled": reply.get("scheduled"), "key_window": reply.get("key_window"), "sent_ms": round((at - due) * 1000, 1)}
            sent = [round(sequence["sent_ms"] + lead - before, 1) for before in plan]
        elif plan:
            ended = self.start(sender)
        self.until(due - LEAD_MS / 1000)
        reply = self.rpc("debug.new_tab", params, opts.duration_ms / 1000 + 180) or {}
        ended()
        mine = 1 + (kind == "idle") + len(sent)  # the tabs that the tool opened: Control-`'s, the idle case's, the keys'
        if "error" in reply:
            row["invalid"] += [f"frame_strip: {json.dumps(reply.get('error'), default=str)[:300]}"] + early
            if goes_on(reply):
                row["call_went_on"] = self.call_end(folder)
            shutil.rmtree(folder, ignore_errors=True)
            self.close_own(own_tabs, mine)
            return row
        after, records = self.pane(), self.opened()
        row.update(frames_of.one_key(reply, "w", 0, opts.tolerance, self.rate))
        row.update({"label": label, "case": kind})
        fact, faults = frames_of.close_of(row, reply.get("spans"), before, after, len(plan))
        fact.update({"case": kind, "new_tab_keys_plan_ms": [-offset for offset in plan], "new_tab_keys_sent_ms": sent})
        if plan:
            fact["new_tab_keys_by"] = KEYS_BY["sequence" if sequence else "calls"]
        if sequence:
            fact["sequence"] = sequence
        row["close_tab"] = fact
        for name in ("content_gone", "content_shown", "strip_first"):
            # A frame of the close that the row's own pictures do not have yet (one file is kept one time).
            if fact.get(name) and fact[name].get("file") and fact[name]["file"] not in (row.get("pictures") or {}).values():
                row.setdefault("pictures", {})[name] = fact[name]["file"]
        opened = frames_of.opened_since(before_opened, records)
        spare = [bool(record.get("spare")) for record in records[len(records) - opened:]]
        low, high = frames_of.records_range("t", len(plan))
        if not low <= opened <= high:
            faults.append(f"input: {len(plan)} New Tab key-downs sent, the app recorded {opened} openings ({low} to {high} are possible)")
        faults += [f"input: the New Tab key-down {index} of {len(plan)} was refused by the app" for index in refused]
        row["invalid"] = ([reason for reason in row["invalid"] if reason not in fact["not_a_fault_for_a_close"]] + early + faults
                          + [fault for fault in (self.display_fault, session_fault, self.launch_fault) if fault])
        row.update({"keys_sent": 1, "lead_ms": reply.get("lead_ms"), "spare": spare, "opening_records": frames_of.records_fact("t", len(plan), spare),
                    "frame_count": reply.get("frame_count"), "mean_interval_ms": reply.get("mean_interval_ms")})
        if kind != "idle":
            # The page that shows after the close, when one does (a terminal has no engine: that is no fault).
            engine = bench_page_engine.page_engine(self.rpc("debug.agent_pane", {"action": "engine"}, 20))
            if opts.page_engine != "any" and bench_page_engine.family(engine) not in (None, opts.page_engine):
                row["invalid"].append(f"engine: the page that shows after the close ran in {engine}, {opts.page_engine} was asked")
        row["page_engine"] = engine
        self.pictures(row, folder, run)
        shutil.rmtree(folder, ignore_errors=True)
        self.close_own(own_tabs, mine)
        return row

    def call_end(self, folder):
        """Waits until the app's frame_strip call that went on after its reply wrote its last file into `folder`:
        whether it came, and after how many pauses."""
        for pauses in range(CALL_END_PAUSES):
            if os.path.exists(os.path.join(folder, LAST_FILE)):
                self.sleep(0.5)  # tool pacing: the call makes its reply after its last file
                return {"ended": True, "pauses": pauses}
            self.sleep(0.5)  # tool pacing: the app still compares and writes its frames
        return {"ended": os.path.exists(os.path.join(folder, LAST_FILE)), "pauses": CALL_END_PAUSES}

    def close(self, opened, own_tabs):
        """Closes the recording's new tabs or workspaces, then Control-`'s terminal tab when the pane still has one
        more tab than before it: each recording of a case starts from the same tabs."""
        if opened:
            self.tools["close_new"](opened)
        if own_tabs is not None and self.count("t") > own_tabs:
            self.tools["close_new"](1)

    def pictures(self, row, folder, run):
        # A row that is not first-is-final by its first content frame alone has no later changed frame: keep it too.
        wanted = (run < self.opts.keep_keys or row.get("changes_after_content") or row.get("invalid")
                  or row.get("content_first_is_last_picture") is False)
        if not wanted or self.kept_in_case >= PICTURES_A_CASE:
            return
        os.makedirs(self.keep, exist_ok=True)
        kept = {}
        for name, file in (row.get("pictures") or {}).items():
            source = os.path.join(folder, file) if file else None
            if source and os.path.exists(source):
                kept[name] = f"{row['label']}-{name}-{file}"
                shutil.copyfile(source, os.path.join(self.keep, kept[name]))
        self.kept, self.kept_in_case = self.kept + len(kept), self.kept_in_case + len(kept)
        row["kept_pictures"] = kept

    def sized(self, cases, report):
        """Each case of the run in order, by name and call. With `--key-tabs`: each case one time for each count, after
        that count's tabs are made (`fill`); the name and the rows' label say the tabs that the app lists directly
        before the case, and `size` has the reason of each row when that count is not the asked one."""
        if not self.opts.key_tabs:
            yield from cases
            return
        for asked in self.opts.key_tabs:
            made = self.fill(asked)
            report["key_tabs"]["sizes"].append(made)
            if made["fault"] and not sum(made["added"].values()):
                # No tab made at this count: its cases would be the count before's again (or the launch's own tabs').
                lists = "no tab" if made["tabs"] is None else f"{made['tabs']} tabs"
                report["stopped"] = (f"key-tabs: {asked} tabs asked and the tool made no tab ({made['fault']}; the app lists {lists}): "
                                     "no case recorded at this count")
                print(f"{MARK} STOPPED {report['stopped']}", flush=True)
                return
            for name, take in cases:
                had, why = self.listing()["tabs"], made["fault"] or "the count changed after the tabs were made"
                if had is None:
                    said, self.tag = f"no list of tabs in the key's workspace before the case ({asked} asked)", f"-tabsnolistof{asked}"
                    fault = f"key-tabs: {asked} tabs asked, the app lists no tab of the shown workspace ({why})"
                elif had == asked:
                    said, self.tag, fault = f"{had} tabs in the key's workspace before the case", f"-tabs{had}", None
                else:
                    said, self.tag = f"{had} tabs in the key's workspace before the case ({asked} asked)", f"-tabs{had}of{asked}"
                    fault = f"key-tabs: {asked} tabs asked, the app lists {had} ({why})"
                self.size = {"asked": asked, "had": had, "fault": fault}
                yield f"{name}, {said}", take

    def head(self):
        """The report's first sentences: whether the app was active (by each row's own read; with no row, by the
        answer after the run's ask: a fact, no condition of a take), the workspace of the keys, the run's ask (its
        reads, its seconds, the key window form of its last read, and how many rows have another form), and for a
        made workspace what the app's list said of its terminals before the app showed it."""
        read, place = [row for row in self.rows if "app_active" in row], self.key_workspace or {}
        yes = sum(1 for row in read if row["app_active"] is True)
        if not read:
            active = {True: "yes", False: "no"}.get((self.activation or {}).get("app_active"), "not known")
        else:
            by = f"({yes} of {len(read)} rows, by the app's answer before each recording)"
            active = "yes" if yes == len(read) else f"no {by}" if not yes else f"NOT IN EACH ROW {by}"
        where = place.get("is", "not known")
        if place.get("shown_by_the_app") is False:
            where = f"NOT the made workspace `{place['name']}` (the app does not show it)"
        elif place.get("name"):
            where += f" ({place['name']})"
        ask = self.activation or {}
        # The form of the read before the first case, and loudly the rows of another form: 2 forms are 2 states.
        others = sum(1 for row in read if row.get("key_window_form") != ask.get("form"))
        form = f", the key window form: {ask.get('form') or 'none'}" + (
            f" (NOT IN EACH ROW: {others} of {len(read)} rows have another form or none; rows of 2 forms are 2 states, no pair)" if others else "")
        asked = "not made" if not ask.get("asked") else f"{ask['reads']} reads of the app's answer, {ask['seconds']:g} s from the ask to the answer{form}"
        said = [f"the app was active: {active}", f"the key's workspace: {where}", f"the ask for the window in front (no activation): {asked}"]
        if "terminals_before_shown" in place:
            had = place["terminals_before_shown"]
            said.append("the key's workspace's terminals before the app showed it: " + (
                "NOT KNOWN (the app's list has no such fact)" if not had else
                f"{had['with_no_shell']} of {had['terminals']} with no shell by the app's list (`dead`; a parked terminal reads so, and its "
                "shell starts when the app shows its workspace)"))
        return said

    def run(self):
        opts = self.opts
        report = {"head": [], "mode": "screen", "keys": opts.keys.split(","), "gaps_ms": [float(g) for g in opts.gaps.split(",") if g],
                  "runs": opts.runs, "duration_ms": opts.duration_ms, "scale": opts.scale, "tolerance": opts.tolerance,
                  "display": opts.display or "as the host has it", "display_hz_asked": self.rate, "build": None,
                  "key_path": "debug.key's sender: the app's own key path, not the keyboard's driver",
                  "numbers": "new_surface_frames.py", "rows": self.rows, "cases": {}}
        # The run's first lines: what the app itself says of its settings and its window (new_surface_look.py).
        report["settings"] = settings = new_surface_look.shown(self.rpc, getattr(opts, "window_look", None), self.sleep, self.launched)
        for line in settings["lines"]:
            print(f"{MARK}-SETTINGS {line}", flush=True)
        if opts.build and os.path.exists(opts.build):
            with open(opts.build, encoding="utf-8") as handle:
                report["build"] = json.load(handle)
        report["launch"] = self.launch
        report["split"], report["chromium"] = opts.split, bench_page_engine.chromium_word(self.rpc("debug.cef", None, 10))
        print(bench_page_engine.chromium_line("new-surface-screen", report["chromium"]), flush=True)
        # An app that does not show the asked look ends the run here: no session is made for a take of another look.
        ended = settings["problem"] and f"window look: {settings['problem']}: no session made, no tab made, no case recorded"
        report["session"] = {"asked": opts.workspaces, "not_made": ended, "as_asked": False} if ended else self.session()
        session_fault = None if ended or report["session"]["as_asked"] else (
            f"session: {opts.workspaces} workspaces asked, the app lists {report['session']['listed_by_the_app']}")
        if opts.key_tabs:
            report["key_tabs"] = {"mix": KEY_TABS_MIX, "limit": KEY_TABS_LIMIT, "sizes": []}
        # The keys' workspace, then the one ask for the window in front and the read of the app's windows: a reason of
        # either ends the run before a tab or a case.
        ended = ended or self.place() or self.ask()
        report["key_workspace"], report["activation"] = self.key_workspace, self.activation
        # The form of the read before the first case (`key_form`; None: no ask, or a stop). 2 runs with 2 forms are no pair.
        report["key_window_form"] = (self.activation or {}).get("form")
        if ended:
            report["stopped"] = ended
            print(f"{MARK} STOPPED {ended}", flush=True)
        # Each case: its name, and the call that makes one row of it. The Close Tab key's cases are its own (the module doc).
        cases = []
        for key in report["keys"]:
            if key == "w":
                cases += [(close_case(kind, opts), lambda run, kind=kind: self.close_one(kind, run, session_fault))
                          for kind in opts.close_cases.split(",") if kind]
                report["close"] = {
                    "cases": [kind for kind in opts.close_cases.split(",") if kind], "gap_ms": opts.close_gap_ms,
                    "hold": {"key_downs": opts.hold_keys, "first_repeat_after_ms": opts.hold_delay_ms, "repeat_each_ms": opts.hold_repeat_ms},
                    "new_tab_keys_by": {"key": KEYS_BY["calls"], "downs": KEYS_BY["calls"], "hold": KEYS_BY["sequence"]}}
                if "hold" in report["close"]["cases"] and not ended and self.hold_off():
                    report["close"]["hold"]["not_run"] = self.hold_off()  # each row of the hold's case says it too
            else:
                cases += [(f"cmd-{key}/{'idle' if not gap else f'{gap:g} ms after a key'}",
                           lambda run, key=key, gap=gap: self.one(key, gap, run, session_fault)) for gap in report["gaps_ms"]]
        taken = []  # each case that ran: its name, its rows and the `--key-tabs` count in work
        for case, take in [] if ended else self.sized(cases, report):
            rows, self.kept_in_case = [], 0
            for run in range(opts.runs):
                row = take(run)
                if self.size:
                    row["key_tabs"] = {"asked": self.size["asked"], "had": self.size["had"]}
                    if self.size["fault"]:
                        row["invalid"].append(self.size["fault"])
                if row.get("no_form"):
                    row["invalid"].append(f"form: directly before the recording {row['no_form']}: the row has no key window form")
                rows.append(row)
                self.rows.append(row)
                said = {name: row.get(name) and [row[name]["frame"], row[name]["ms"]] for name in ("tab", "content_first", "content_final", "final")}
                tabs = f" workspace_tabs_before={row['workspace_tabs_before']}" if "workspace_tabs_before" in row else ""
                print(f"{MARK}-ROW {row['label']}: {'INVALID ' + '; '.join(row['invalid']) if row['invalid'] else 'valid'} "
                      f"{json.dumps(said)} first_is_final={row.get('first_is_final')} whole_window={row.get('whole_window')} "
                      f"changes_after_content={row.get('changes_after_content')} "
                      f"refresh_ms={row.get('refresh_ms')} rate_share={row.get('rate_share')} capture={row.get('capture')}{holes(row)}{tabs} "
                      f"app_active={row.get('app_active')} shell_window_is_key={row.get('shell_window_is_key')} "
                      f"key_window_form={row.get('key_window_form')}", flush=True)
                if row.get("call_went_on"):
                    break
            report["cases"][case] = self.case_fact(rows, self.size)
            taken.append((case, rows, self.size))
            close = frames_of.close_cell(report["cases"][case]["close"]) if "close" in report["cases"][case] else ""
            went_on = rows[-1].get("call_went_on") if rows else None
            if went_on:
                report["cases"][case]["ended_early"] = f"after {len(rows)} of {opts.runs} rows: frame_strip answered `timeout` and the app's call went on"
                if not went_on["ended"]:
                    report["stopped"] = (f"after {rows[-1]['label']}: the app's frame_strip call did not end in "
                                         f"{went_on['pauses']} pauses of 0.5 s: no later recording")
            early = report["cases"][case].get("ended_early")
            print(f"{MARK} {case}: {frames_of.cell(report['cases'][case])}{close}{' (THE CASE ENDED EARLY ' + early + ')' if early else ''}", flush=True)
            if report.get("stopped"):
                print(f"{MARK} STOPPED {report['stopped']}", flush=True)
                break
        # The read of the app's windows after the last case: a window that is not the same makes each row INVALID.
        if taken:
            self.after(report, taken)
        # (R) the report: the frame and the 3 words of both reads (no title, no word of another app).
        report["window"] = self.window_facts
        if self.window_facts:
            print(f"{MARK}-WINDOW {json.dumps(self.window_facts)}", flush=True)
        # The head's first sentences keep their places; then the recorder's lost rows, with an asked rate the limit of
        # its check (and the asked rate's margin when a valid row's is small), then the app's settings lines.
        rate = [said for said in (frames_of.rate_limit_sentence(self.rate), frames_of.rate_margin_sentence(self.rows)) if said]
        report["head"] = self.head() + [frames_of.recorder_sentence(report["cases"])] + rate + settings["lines"]
        print(f"{MARK}-HEAD {'; '.join(report['head'])}", flush=True)
        # A stopped run is not a whole run: the driver ends with this code (0: each case ran).
        report["exit_code"] = STOPPED_EXIT if report.get("stopped") else 0
        if opts.json:
            with open(opts.json, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=1)
        if opts.screen_tgz:
            os.makedirs(self.keep, exist_ok=True)
            with open(os.path.join(self.keep, "report.json"), "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=1)
            with tarfile.open(opts.screen_tgz, "w:gz") as archive:
                archive.add(self.keep, arcname="new-surface-screen")
        print(f"{MARK} report only: {len(self.rows)} rows, {sum(1 for row in self.rows if row['invalid'])} INVALID, "
              f"{self.kept} pictures kept" + (f"; STOPPED {report['stopped']}" if report.get("stopped") else ""), flush=True)
        return report


if __name__ == "__main__":
    # The entry's cleanup, after it ended the tag's processes: `new_surface_screen.py --fresh-session TAG`.
    if len(sys.argv) != 3 or sys.argv[1] != "--fresh-session":
        sys.exit("use: new_surface_screen.py --fresh-session TAG (the mode itself: cmd-n-paint-e2e.py --screen)")
    fresh_session(sys.argv[2])
