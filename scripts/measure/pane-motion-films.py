#!/usr/bin/env python3
"""Films of pane motions: one movie for each act, for a person to look at. This script judges no film.

Launches a tagged bench `cmux DEV <tag>.app` with the repository's bench launcher (bench_launch.py `BenchApp`), makes
a session with the repository's one session maker (scripts/perf-bench/session_real.py make), and then, for each film
id of --films: a new workspace with the film's panes, the app's own recorder (`debug.motion` record_start: a movie of
the display from the window's top left, written off the main thread), the film's keys, record_stop, and the close of
what the film made. Out: <out>/<id>.mov, <out>/<id>.mov.frames.json (the display time of each frame) and
<out>/films.json (one row for each film: `made`; `not_made` = a check of the film's acts refused it; `not_run` = the
tool did not start it or the app refused a key; each with the reason; `made, the new window not checked in the
movie` = the film of a new window after the checks of its acts, see below).

The sources of the acts, and their limits (each row says which it used):
  keys     `debug.key`: real key events on the app's own queue; not the HID tap, not the window server. A held key
           is one key-down and its repeats (the first after --repeat-delay-ms, then one each --repeat-ms). The keys
           have 2 forms (--launch-form): `activate` = the app is launched as a person's app (it takes the keyboard)
           and each act's keys are one sequence in the key window, played by the app's clock; `one-key` = the
           launcher's usual launch (the app never takes the keyboard) and each key-down is one call at its time by
           this script's clock, into a window that is not key; that form has no repeat flag, so a film with a held
           key is `not_run` in it. `auto` (the default) = `activate`, and if its preflight fails, one new launch as
           `one-key`. Each launch and each film's row say the form. In the `activate` form the key window of each
           sequence follows the focus (`focus_word`): the page's own window when a Chromium page has the keys (after
           a Cmd-T, the New Tab page), else the shell window; each act's row says the word. The read of the focus
           and the keys are 2 calls, and after a Cmd-T the app moves the keys to the new page in that time. So when
           the app refuses the word (`... window did not become key`, `no Chromium page window for pane`), the
           script reads the focus one more time and sends the keys one more time. An act has 3 sends at most, in
           one case: when the app refuses `page` at that second send also (a tab whose page window the app does
           not find, or 2 cmux windows), ONE last send goes to the shell window. Each refusal is in the act's
           row (`refused_as`, a list) or in the PREFLIGHT line. By a read of the app's source, the app refuses a
           word before it posts a key, so a send after such a refusal does not do the act 2 times. After each
           other error (a call that timed out) the app can have the keys: a send that timed out is never sent
           again, in each form. A limit: for a `shell` word that it refuses, the app has moved the shell window
           to the front before the refusal, and a film can show that. A focus read that fails gives the word
           `shell`; the act's row (`focus_not_read`) and the PREFLIGHT line say that no read gave the word.
           The launcher starts the app's binary directly, and on a display Mac such a process did not become the
           active app; so the `activate` form then asks
           LaunchServices one time (`open BUNDLE`, as a click on the Dock icon of an app that runs), and `PREFLIGHT activate:`
           says what made the app active (`by=launch`, `open`, `none`), which app is frontmost, and which
           instances of the app run. With `by=none` the `activate` form is not run (`forms_not_run` in the report
           and in each row that is not of that form) and `one-key` is next. A second instance after the open ends
           that launch and each launch after it; it gets one SIGTERM if launchd started it, so it does not stay in
           the session of the Mac.
  pointer  `debug.mouse`: mouse events on the app's own queue, one request for each step of a drag, paced by this
           script; the system pointer does not move in the film. The row has the step rate of the app's input journal.
  action   `action.run`, for an act with no default key; its label says so. The workspace switch (`P17`) is by the
           action `goToWorkspace` with the id of a workspace of the session too: a key of Command and a number shows
           the ROW of the sidebar with that number, and that is a workspace of the session only when no other row
           (the Home, the App Store, a pinned row) is above it. So that film shows no key's path.
The panes: `redraw` = htop, else nvim, else /usr/bin/top (--program); `stream` = /sbin/ping on the loopback;
`page` = a Chromium tab on a page of this script's local server (no network); `chat` = the agent chat page with a
synthetic thread that streams by the page's own debug hook (`debug.agent_pane` stream): no agent runs and the launch
guard stays. That hook runs only under CMUX_NEXT_AGENT_PANE_MOCK=1 (the page then talks to its in-page mock, not to
a daemon), and the mock also changes the New Tab page. So --chat-mock=auto (the default) makes 2 launches of the same
app: the mock off (the product's own pages) for each film but the `A-` and `M-` films, then the mock on for those;
in a launch with the mock off, the `chat` pane of the other set-ups is the product's New Tab page. --chat-mock=1 or 0
is one launch in that state (with 0, the `A-` and `M-` films are not_run). Each row says its launch's state.
The virtual display of the entry script is 1x: a film has 1 pixel for each point.

The preflight: directly after each launch and before the session is made, one of each thing that a film needs runs
in a workspace of its own and is read back (`preflight`, 2 minutes at most): the display link's frames, the
recorder's frames, one new tab and its close, one split, one zoom in and out, each key as a film sends it. One that
the app refuses, or that changes nothing, prints the app's own words (`PREFLIGHT <name> FAILED: ...`, with what the
app said of the key) and ends that launch; with no other launch form left the run ends at once with exit 1. So a
fault of the key path costs minutes, not a session and a list of films with no motion in them. The zoom is the one
check that does not end the launch, and the 2 minutes do not count it: its key is sent after the split's new pane is
settled, and if the key changes nothing, the zoom is made by `action.run toggleSplitZoom`; each film with a zoom then
says `zoom by action.run, not by a key` in its row and in its `keys` words. If the action changes nothing too, only
the films with a zoom are `not_run`. In a film, a key or an action that the app refuses makes the film `not_run`
with the app's words.

The checks of a film (a row says `made` only after them; the script still judges no film: the checks say if the acts
happened and if something was over the window, not how a motion looks). They use 3 debug reads of the app:
`debug.dialog` (`dialogs`, each with `visible`), `debug.focus` (`windows[].model.overlays`: a sheet, the palette, a
rename field, the group editor) and `debug.toast` (`windows[].toasts` = the messages on the screen; `refusals` = each
refusal message of the app so far, the last 100).
  before each take (after the set-up, before the recorder starts): a visible dialog or an overlay makes the film
      `not_made` (`before the take: ...`, the dialog's title and lines word for word) and STOPS the launch: each later
      film of it is `not_run` with that reason. For a message on the screen the script reads again for 18 s at most (a
      message goes by itself; the script closes none, `message_waited` in the row), then the film is `not_made` and
      the launch goes on. A read that fails, or a reply that does not say it (no list: an older app; a dialog with no
      `visible` word; no window; a window with no list of its messages), is `not_made` too: the script does not know.
      A read that fails in those 18 s has its own reason: it is not `a message stayed`.
  after the acts: `not_made` for each new entry of `refusals` (`the app refused in the film: ...`), for a visible
      dialog (`the app asked in the film: ...`), for an overlay, and when the pane count before and after does not
      change by what the film's acts make (+1 a split, -1 a close of a pane, 0 each other film). More, only for the
      films of a split with its close, a zoom and one tab (`act_check` in the row says which; each other row says
      `act check: the refusal list, the dialogs and the pane count only`): the count of zoomed panes before the key
      that goes back (1) and at the film's end (0); the tab count of the pane; for a film with a speed the count of
      `layout` spans in its span record (`layout_spans`; a film with no speed has no span record: `not recorded`).
      A count that the script could not read is `not read` in the row, never 0, and the film is `not_made`: a layout
      read that gave no workspace (the pane count, the zoomed panes), a tab read that gave no tab.
      A film of a split and then a close reads the pane with the focus between the 2 keys: when that is not a NEW
      pane, the close is NOT sent (the app asks before it closes a terminal with a program) and the film is `not_made`.
      The film of a new window (`P16`) reads the app's window list (`debug.window_list`) before the take and, after
      its key, again each 0.25 s for 20 s at most, until the list has ONE new window of the kind `main` that the app
      says is on the screen (`visible`, not `occluded`, not `miniaturized`); the film's tail starts only then
      (`new_windows`, `new_window_at_s` in the row). No such window in that time, or a list that the script could
      not read, is `not_made`. This is the app's word of its window, not a look at the picture.
      THE MOVIE OF THAT FILM IS NOT CHECKED. By a read of the app's source, the recorder makes its list of the app's
      windows ONE time, at its start, and the film's key makes the window after that: the window can be out of each
      frame of the movie. So the row's word is `made, the new window not checked in the movie`, never `made`, until
      a run on a Mac with a look at the movie's frames shows the window there. The movie keeps its name. That word
      does not count as made in the last line and in the exit code; a line `PANE-FILMS made, the new window not
      checked in the movie: <id>` says it.
      2 more checks of that film. The place (`new_window_place`): the recorder's rectangle goes from the top-left
      corner of the film's window to the right and bottom edges of its screen, so a new window whose whole frame
      (the window list's `frame`) is left of, or above, that corner is `not_made`. With 2 or more windows of the
      kind `main` before the take, or with no frame in the list, the row says `not checked: ...`. A window on
      another display is not found. The take's time (`take_s`, the script's clock from the recorder's start to the
      end of the film's tail): the recorder ends by itself after 30 s, so a take of more than 29 s is `not_made`
      (a read that stalls can put the window after the movie's end).
      The workspace switch (`P17`) shows 2 workspaces that the session's maker made (the workspaces that the app
      lists after the maker and did not list before it): before the take the first one and then the film's own
      workspace again, in the take that first one and then the second one, which the script did not show before.
      After each switch the script reads for 10 s at most if a window shows that workspace: `not_made` if none does.
      A launch with fewer than 2 such workspaces (--workspaces 0) makes the film `not_run`. `the first time` = the
      script never showed it; the app has no read that says if it drew the workspace before.
  a window that the film made is closed at the film's end (`debug.window.focus` with the window's model key, then the
      action `closeWindow`). `left_open` in the row is from the action's reply and from reads of the layout after it,
      for 5 s at most: `a window (still in the layout 5 s after closeWindow)`, or `a window (the layout after
      closeWindow was not read)` when the last read gave no layout: a window is not closed because no read said so.
  a dialog that the film opened gets ONE `debug.dialog` `dismiss` (the app's Cancel) at the film's end, so that it is
      not over the next film; the row says `the tool sent Cancel` (`dialog`). If the app does not take it, the launch
      stops. A film that is `not_made` keeps its movie: it shows what the app did. The movie gets the name
      `<id>.not-made.mov` (its frame file `<id>.not-made.mov.frames.json`), and the row has it as `take_file`, not as
      `file`. So does the movie of a film that is `not_run` after its recorder started (a key that the app refused).

The animation speed: the 6 films of the group `cap` have a speed (`fast`, the app's default, or `normal`; an id with
`.N` is at `normal`), and so do the 8 films of the group `pages` (`fast`). For such a film the script reads the speed that the app has (`speed_before`), sets the film's
speed by `debug.motion` `speed` before the film's set-up (in the app's memory only: the app writes no settings
file), and reads the app's reply into the row: its speed word (`speed`), and if a pane motion animates at all
(`reduce_motion`, `animations_enabled`, `pane_animations`, `disabled_categories`). It makes no film when the app
gave back another word, or when a pane motion does not animate (Reduce Motion on the Mac, a switch that is off, or
the category `panes` in `disabled_categories`: a motion is then one frame at each speed). An app whose reply has
none of these fields gets its film: the script cannot know, and the row says `null`. At the film's end it sets the
speed of before (`speed_after`); if the app does not give that word back, that row and the row of each film after
it in the launch say so (`speed_fault`), and the run's end prints one line (`PANE-FILMS speed fault: ...`) with
each film that was made after it with no speed call of its own. The exit code does not say it.
A film shows no number, so the row also gets the app's own record of the motions from before the film's first act
to its end (`spans`, by `debug.motion` `start` and `stop`: the name, `ms` and `at_ms` of each span that ended, 60
at most: each span with the name `layout`, and the other spans while there is room, in the app's order;
`spans_total` = how many the app gave, `spans_cut` = how many of them are not in the row; `speed_at_stop` = the
app's speed word at the record's end: a load
of the app's settings file in the film puts the file's speed back), and the times of the app's source for that
speed (`source_ms`). The record has no name for an act: by a read of the app's source, each pane motion (a split, a
close, a zoom, its way back) is one span with the name `layout`, from its first frame to rest, which can be later
than its visible end; a zoom that is turned before its rest stays ONE span; the list is in the order of each span's
end and has the spans of each other animator too (a tab strip, the sidebar). A pane motion that is at rest in its
first frame is a span too (the app opens the span when the motion starts and closes it at the first frame that says
`at rest`), so the count of `layout` spans says how many motions the app started, not that a pane moved for more
than one frame: `layout_ms` in the row has the `ms` of each `layout` span, in the record's order.
The turned zoom (`T-ZT`) is 2 zoom keys with the half of the zoom's time ASKED between them (`gap_asked_ms`); no row
has the true gap. In the `activate` form it is one sequence on the app's clock, and the app posts each key when its
main thread gets to it. In the `one-key` form it is 2 calls on this script's clock: `key_down_ms` has the time of
each SEND, and the gap is true only if the first call returns in less time than the gap. A film with no speed sends
none of these calls.

  pane-motion-films.py --app <cmux DEV tag.app> --films kinds [--workspaces N --live-shells K] --out DIR
  pane-motion-films.py --films list
--films: ids with commas, or `kinds` (9 films: T, B, A by D, SD, Z), `mixed`, `plist` (P03 to P23), `extra`
(X01 to X16: each pane action with a default key that has no other film), `cap` (6 films: the split with its close,
the zoom and the turned zoom, each at `fast` and at `normal`), `pages` (8 films: a split with its close, and a zoom,
on a pane that shows a Home tab (H), a Markdown file (D), Settings (S), and on the Chief's tab in the app's own Home
workspace (C): the script opens each page by the app's action and makes no film when the pane does not show it; for
C it makes no workspace, and it closes again what a film left in the Home workspace), `close` (3 films: a split with
its close in a row of 2 terminals (`T-C`, a film of `cap` too), of 2 browser pages (`B-C`) and of 2 chats (`A-C`), each
at `fast`: the close goes to the new pane of the split only), `all`. Exit 0 = each film asked for is
made; 2 = some are made and some are not; 1 = the preflight failed, or no film is made; 3 = not run (no app, an id
that is not known). Only `made` counts: a film that is `not_made` is not made, and a film with the word `made, the
new window not checked in the movie` is not counted.

films.json has `build`: the form of the app's build, as the entry script read it from the reload's log
(build-flags.py; --build FILE): the reload's `bench configuration` line, the optimization settings of the build's
command line, and the count of the Swift compiler's command lines with each optimization level. With no file it
says `not_read`.

--window-look: the look of the films' window (scripts/cmux-next/window_look.py has the keys). With no option, and
with `opaque`, the launch is the launcher's own (an opaque window) and films.json is as before. With KEY=VALUE parts
(for a window with a picture background: `background=NAME,opacity=N,blur=KIND`) the launch's config holds the named
keys and no other key, and after the window's placement the script asks the app itself what the window shows (its
settings answer and its backdrop): a `PREFLIGHT window look:` line, the launch's `window_look` in films.json (the
look as the app resolved it), `window_look` at the top (the option's keys) and in each film's row (the look's name).
A window that does not show the look gets `PREFLIGHT window look FAILED:` and no film: no other launch form is
tried. `behind=checker|stripes` is refused here (exit 3: this script makes no panel behind the window). The recorder
films the app's own windows only: what is behind a window with no picture is not in a film.
A FILM OF A LOOK HAS THE LOOK'S KIND IN ITS NAME: its id in films.json and its files are `<id>-<kind>` (`T-D-picture`,
`T-D-picture.mov`), so the films of 2 looks do not have the same name. The kind is one word from the app's own answer
(window_look.py `look_kind`): `picture`, `glass` or `seethrough`; it has no value of the option and no picture's
name. `--films` takes the ids without it. A window that the app shows as opaque keeps the ids of an opaque run, and
so do the rows of a run in which no launch showed the look. films.json has the kind as `window_look.kind` and, in
each film's row, as `window_look_kind`.
"""
import argparse, importlib.util, json, os, platform, re, shutil, signal, subprocess, sys, threading, time, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.join(HERE, "..", "cmux-next")
sys.path.insert(0, NEXT)
import bench_launch  # noqa: E402
import window_look as looks  # noqa: E402
SPEC = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(NEXT, "perf-stress-session.py"))
STRESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STRESS)
MAKER = os.path.join(HERE, "..", "perf-bench", "session_real.py")

KEY = {"d": 2, "h": 4, "x": 7, "c": 8, "b": 11, "w": 13, "r": 15, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "=": 24,
       "-": 27, "0": 29, "o": 31, "p": 35, "return": 36, "l": 37, "n": 45, "tab": 48, "`": 50, "left": 123, "right": 124,
       "down": 125, "up": 126, "cmd": 55, "shift": 56, "opt": 58, "ctrl": 59}
MODIFIERS = ("ctrl", "opt", "shift", "cmd")
NAMES = {"return": "Enter", "`": "backtick", "=": "=", "-": "-"}
ONE_KEY = "one key for each call, no repeat flag, the script's clock"
KEY_REFUSALS = ("window did not become key", "no Chromium page window")  # the app's 2 refusals of a `key_window` word
MOVES = ("reduce_motion", "animations_enabled", "pane_animations")  # the fields of `debug.motion` that say if a pane motion animates
STILL = "the app animates no pane motion now, so a film at a speed would show none"
NOT_READ = "not read: `fast`, the app's default, is set at the film's end"
ZOOM_CHORD, ZOOM_ACTION, BY_ACTION = "cmd+shift+return", "toggleSplitZoom", "zoom by action.run, not by a key"
LAUNCH_FORMS = {"auto": ["activate", "one-key"], "activate": ["activate"], "one-key": ["one-key"]}
PREFLIGHT_S = 120
LEAD_S, MIN_FILM_S, TAKE_S = 1.0, 4.5, 30
DRAG_RATE = 120
PING = "/sbin/ping -i 0.2 127.0.0.1"
# How long the reads before a take go on while a message is on the screen. By a read of the app's source, with its
# default tuning, a message shows for 2 times the seconds that its caller asks, and 6 s or more: a refusal 8 s, the
# undo message of a close 12 s, a refusal with a sign-in offer 16 s (the longest one of a film's act). 16 s and 2 s
# for the reads. The pointer on a message holds it, and a message with no end time does not go: `not_made` then.
OVERLAY_S = 18
# How long the film of a new window reads the app's window list for the window, and how long a workspace switch reads
# for the workspace in a window. In a run on a Mac with a session of 800 workspaces the new window was not in the
# picture 3.7 s after its key.
WINDOW_S, SHOW_S = 20, 10
# How long the tool reads the layout after the close of a film's window: the close settles after the action's reply.
CLOSE_S = 5
# The row's word for the film of a new window whose acts passed their checks. The recorder makes its list of the app's
# windows at its start (by a read of the app's source), so the movie can lack the window, and no check reads the movie.
MOVIE_NOT_CHECKED = "made, the new window not checked in the movie"
OUT_OF_THE_RECTANGLE = "out of the recorder's rectangle"
ACT_ONLY = "act check: the refusal list, the dialogs and the pane count only"
NO_NEW_PANE = "the split made no pane (the pane with the focus is not a new pane), so the close was not sent"
SETUPS = {"T": ("row", ("redraw", "stream")), "B": ("row", ("page", "page")), "A": ("row", ("chat", "chat")),
          "M": ("row", ("redraw", "page", "chat")), "P": ("grid", ("redraw", "stream", "page", "chat")),
          "R": ("row", ("redraw", "stream", "shell", "shell", "shell")),
          # The group `pages`: a pane that shows one of the app's own pages, beside a terminal with a program. `C` makes
          # no workspace: the Chief's tab is a tab that the app itself puts into its Home workspace.
          "H": ("row", ("home", "redraw")), "D": ("row", ("markdown", "redraw")), "S": ("row", ("settings", "redraw")),
          "C": ("home", ("chief",))}
# A pane kind that is one of the app's own pages: (the action that opens it, the page's id in the layout), by a read
# of the app's source. `home.tab` and `openSettings` take no target: they open in the pane with the focus.
APP_PAGES = {"home": ("home.tab", "home-tab"), "markdown": ("openMarkdownFile", "markdown"), "settings": ("openSettings", "settings")}
PAGE_SETUPS = {"H": "a Home tab", "D": "a Markdown file", "S": "Settings", "C": "the Chief's tab in the Home workspace"}
MARKDOWN = "# Pane motion films\n\n" + "".join(
    f"## Part {part}\n\n" + "A line of text for the film of a pane that shows a Markdown file. " * 4 + "\n\n- one\n- two\n- three\n\n" for part in range(1, 13))
HOME_DOCK = "not asked: the app's own Home workspace"
MOCK_SETUPS = "AM"  # a film of these needs a chat thread that streams: only a launch with the page mock has one
KINDS = {"T": "2 terminals with a program", "B": "2 loaded browser pages", "A": "2 chats with a thread that streams",
         "M": "a terminal, a page and a chat"}
LIMITS = ["1x display: 1 pixel for each point", "the keys are posted to the app's own queue (debug.key), not the HID tap",
          "a chat pane has a synthetic thread that streams by the page's own debug hook; no agent runs",
          "a page pane shows a local page of the script, not a real site",
          "a drag is made by a debug command (debug.mouse); the system pointer is not shown"]


def K(chord, presses=1, gap=250, hold=0.0):
    """Keys: `chord` ("cmd+shift+d"; "cmd+d,w" = D then W under one Command), `presses` times with `gap` ms from
    key-down to key-down, or held `hold` seconds ("tabs": until 2 tabs of the pane are left)."""
    return ("keys", chord, presses, gap, hold)


def W(seconds):
    return ("wait", seconds)


def A(action, target=""):
    return ("action", action, target)


def G(index):
    """Shows the workspace `index` (0 = the first one) of the session's workspaces by the action `goToWorkspace`: no key."""
    return ("go", index)


def window_place(before, new):
    """Where the new window is against the film's window, by their frames in ONE reply of the app's window list
    (AppKit's frames: x, y = the bottom-left corner, y goes up). The recorder's rectangle goes from the top-left corner
    of the film's window to the right and bottom edges of its screen (by a read of the app's source). `before` = the
    frame of each `main` window that the app had before the take; `new` = the frame of each new one."""
    if len(new) != 1:
        return f"not checked: {len(new)} new windows"
    if len(before) != 1:
        return f"not checked: {len(before)} windows of the kind `main` before the take"
    try:
        (old,), (window,) = before, new
        left, above = window["x"] + window["width"] <= old["x"], window["y"] >= old["y"] + old["height"]
    except (TypeError, KeyError):
        return "not checked: a window with no frame in the list"
    if left or above:
        return f"{OUT_OF_THE_RECTANGLE}: the whole new window is {'left of' if left else 'above'} the top-left corner of the film's window"
    return "not left of and not above the top-left corner of the film's window"


def film(ident, title, setup, acts, **more):
    return {"id": ident, "title": title, "setup": setup, "acts": acts, **more}


ZOOM = [K(ZOOM_CHORD), W(1.6), K(ZOOM_CHORD)]
# ("tabs",): a read of the pane that the close takes. The close goes only to a NEW pane (a shell with no program): the
# app asks before it closes a terminal with a foreground program, and a film behind that question is no film of a close.
SPLIT_CLOSE = [K("cmd+d"), W(1.5), ("tabs",), K("cmd+w")]
CANVAS, CANVAS_OFF = [K("ctrl+cmd+c"), W(1.2)], [K("ctrl+cmd+c"), W(0.6)]
FILMS = [made for kind in "TBAM" for made in (
    film(f"{kind}-D", f"Cmd-D on {KINDS[kind]}", kind, [K("cmd+d")], change=1),
    film(f"{kind}-SD", f"Cmd-Shift-D on {KINDS[kind]}", kind, [K("cmd+shift+d")], change=1),
    film(f"{kind}-Z", f"Zoom in and out on {KINDS[kind]}", kind, ZOOM))]
FILMS += [
    film("P03", "Close a pane (its last tab)", "R", [K("cmd+w")], focus=2, change=-1),
    film("P04", "Close a tab with siblings", "P", [K("cmd+w")], tabs=3, tab_change=-1),
    film("P05", "One new tab", "P", [K("cmd+t")], tab_change=1),
    film("P06", "New tab held 3 s", "P", [K("cmd+t", hold=3.0)], tail=2.0),
    film("P07", "New tab held, then 5 closes", "P", [K("cmd+t", hold=1.5), W(0.4), K("cmd+w", presses=5, gap=200)], tail=2.0),
    film("P08", "Close tab held", "P", [K("cmd+w", hold="tabs")], pre=[K("cmd+t", presses=12, gap=150), W(1.5)], tail=2.0),
    film("P09", "Next tab held, then the tab before held", "P", [K("ctrl+tab", hold=1.2), W(0.4), K("ctrl+shift+tab", hold=1.2)], tabs=5),
    film("P10", "Zoom in and out with 4 panes", "P", ZOOM),
    film("P11", "Resize by a held key", "P", [K("ctrl+shift+l", hold=1.0), W(0.3), K("ctrl+shift+h", hold=1.0)]),
    film("P12", "Divider drag, then a fast back-and-forth", "P", [("divider",)]),
    film("P13", "A split, then a close, in a row of 5 panes", "R", SPLIT_CLOSE, focus=2),
    film("P14", "A tab dragged to another pane", "P", [("tab",)], tabs=2),
    film("P15", "Focus moved pane to pane", "P", [K(f"opt+cmd+{way}") if way else W(0.5) for way in ("right", "", "down", "", "left", "", "up")]),
    film("P16", "A new window", "P", [K("shift+cmd+n")], crop="frame", tail=2.5, windows=1),
    film("P17", "A workspace switch: one shown before, one shown the first time", "P", [G(0), W(1.5), G(1)],
         pre=[G(0), W(1.0), ("show",)], tail=2.0),
    film("P18", "Sidebar hidden and shown", "P", [K("cmd+b"), W(1.2), K("cmd+b")]),
    film("P19", "A column docked and not docked", "P", [K("ctrl+cmd+p"), W(1.5), K("ctrl+cmd+p")], focus=1, dock=False),
    film("P20", "A pin and an unpin", "P", [A("palette.toggleWorkspacePin", "workspace"), W(1.2), A("palette.toggleWorkspacePin", "workspace")]),
    film("P21", "A new workspace and its close", "P", [K("cmd+n"), W(1.8), K("shift+cmd+w")], tail=2.0),
    film("P22", "A split, then a close after 60 ms", "P", [K("cmd+d,w", gap=60)]),
    film("P23", "Window cycle between 3 windows: 5 presses, then held", "P", [K("cmd+`", presses=5, gap=250), W(1.0), K("cmd+`", hold=1.0)],
         pre=[K("shift+cmd+n", presses=2, gap=1200), W(1.5)], crop="frame", tail=2.0),
    film("X01", "New column", "P", [K("ctrl+cmd+x")], change=1),
    film("X02", "New row", "P", [K("ctrl+shift+cmd+x")], change=1),
    film("X03", "New pane, layout by the app", "P", [K("ctrl+cmd+n")], change=1),
    film("X04", "Even sizes", "P", [K("ctrl+cmd+=")], pre=[K("ctrl+shift+l", hold=0.8), W(0.5)]),
    film("X05", "Focus by pane number", "P", [K("ctrl+cmd+2"), W(0.5), K("ctrl+cmd+3"), W(0.5), K("ctrl+cmd+4"), W(0.5), K("ctrl+cmd+1")]),
    film("X06", "Flash of the focused pane", "P", [K("shift+cmd+h")]),
    film("X07", "Terminal text larger, 3 presses", "P", [K("cmd+=", presses=3, gap=400)]),
    film("X08", "Terminal text smaller, 3 presses", "P", [K("cmd+-", presses=3, gap=400)]),
    film("X09", "Terminal text size reset", "P", [K("cmd+0")], pre=[K("cmd+=", presses=3, gap=200), W(1.0)]),
    film("X10", "Canvas layout on and off", "P", [K("ctrl+cmd+c"), W(1.6), K("ctrl+cmd+c")]),
    film("X11", "Canvas overview in and out", "P", [K("ctrl+cmd+o"), W(1.6), K("ctrl+cmd+o")], pre=CANVAS, post=CANVAS_OFF),
    film("X12", "Canvas tidy", "P", [K("ctrl+cmd+t")], pre=CANVAS, post=CANVAS_OFF),
    film("X13", "Canvas: show the focused pane", "P", [K("ctrl+cmd+r")], pre=CANVAS + [K("opt+cmd+-", presses=3, gap=200), W(1.0)], post=CANVAS_OFF),
    film("X14", "Canvas zoom in, 3 presses", "P", [K("opt+cmd+=", presses=3, gap=400)], pre=CANVAS, post=CANVAS_OFF),
    film("X15", "Canvas zoom out, 3 presses", "P", [K("opt+cmd+-", presses=3, gap=400)], pre=CANVAS, post=CANVAS_OFF),
    film("X16", "Canvas zoom reset", "P", [K("cmd+0")], pre=CANVAS + [K("opt+cmd+=", presses=3, gap=200), W(1.0)], post=CANVAS_OFF),
]
# The films of the animation speeds. The visible end of each of their springs, for the film's row, by a read of the
# app's source. `fast`: the source's own numbers (MotionTunables.swift). `normal`: each response is 1.5 times longer,
# 0.25 s at most (MotionPolicy.swift); the source gives the end of the zoom at that response (294 ms), and each other
# number is this script's arithmetic (1.18 times the response, the source's factor): the source does not give it.
ARITHMETIC = "by arithmetic: the source gives no number"
SOURCE_MS = {"fast": {"zoom": "235 ms", "unzoom": "177 ms", "split": "101 ms", "paneClose": "75 ms"},
             "normal": {"zoom": "294 ms", "unzoom": f"about 266 ms ({ARITHMETIC})", "split": f"about 150 ms ({ARITHMETIC})",
                        "paneClose": f"about 113 ms ({ARITHMETIC})"}}
ZOOM_MS = {"fast": 235, "normal": 294}  # the turned zoom sends its second key at the half of this time
FILMS += [made for speed, mark in (("fast", ""), ("normal", ".N")) for half in ((ZOOM_MS[speed] + 1) // 2,) for made in (
    # The set-up `T`: in runs on a Mac its row of 2 took a third pane in the launcher's window with the docked column,
    # and a row of 3 took no fourth one (by a read of the app's source, a split with no room is refused, not made).
    film("T-C" + mark, f"A split, then a close, in a row of 2 terminals, speed {speed}", "T", SPLIT_CLOSE, speed=speed,
         springs=("split", "paneClose"), layout=(2, 2)),
    # `T-Z.2`: a new take of the act of `T-Z`, with the speed set and read back; the id of a film does not change.
    film("T-Z" + (mark or ".2"), f"Zoom in and out on {KINDS['T']}, speed {speed}", "T", ZOOM, speed=speed, springs=("zoom", "unzoom"),
         layout=(2, 2)),
    film("T-ZT" + mark, f"Zoom turned back at its half ({half} ms asked from key to key), speed {speed}", "T",
         [K(ZOOM_CHORD, presses=2, gap=half)], speed=speed, springs=("zoom", "unzoom"), layout=(1, 2)))]  # a turned motion can stay ONE span
CAP = [spec["id"] for spec in FILMS if spec.get("speed")]
# The films of the group `pages`, after CAP (they are no films of the group `cap`): a split with its close, and a zoom,
# on a pane that shows one of the app's own pages. Each has the speed `fast` (the app's default) set and read back, so
# the app records the film's motions: the row has `spans`, and it says `made` only with the 2 `layout` spans of its acts.
FILMS += [made for kind, name in PAGE_SETUPS.items() for made in (
    film(f"{kind}-C", f"A split, then a close, on {name}", kind, SPLIT_CLOSE, speed="fast", springs=("split", "paneClose"), layout=(2, 2)),
    film(f"{kind}-Z", f"Zoom in and out on {name}", kind, ZOOM, speed="fast", springs=("zoom", "unzoom"), layout=(2, 2)))]
# The films of the group `close`: `T-C` (a film of the group `cap` too) and the same act on the 2 other pane kinds, after
# CAP (the 2 new ones are no films of the group `cap` and none of the group `kinds`). The new pane of the split is the
# pane that the close takes, whatever its page is: the read between the 2 keys says its tab kinds, and a close that would
# take a pane of the set-up is not sent.
FILMS += [film(f"{kind}-C", f"A split, then a close, in a row of {KINDS[kind]}, speed fast", kind, SPLIT_CLOSE, speed="fast",
               springs=("split", "paneClose"), layout=(2, 2)) for kind in "BA"]
CLOSE = ["T-C", "B-C", "A-C"]
GROUPS = {"kinds": lambda i: i[0] in "TBA" and "-" in i and i not in CAP and i not in CLOSE, "mixed": lambda i: i.startswith("M-"),
          "plist": lambda i: i[0] == "P", "extra": lambda i: i[0] == "X", "cap": lambda i: i in CAP,
          "pages": lambda i: i[0] in PAGE_SETUPS and "-" in i, "close": lambda i: i in CLOSE, "all": lambda i: True}


def key_steps(chord, presses=1, gap_ms=250, repeats=0, delay_ms=0, every_ms=0):
    """`chord` as `debug.key` steps: the modifiers go down first and stay down; each key is pressed `presses` times
    with `gap_ms` from key-down to key-down, each key-down with `repeats` auto-repeats behind it (a held key: the
    first repeat after `delay_ms`, the next ones each `every_ms`)."""
    names = chord.split("+")
    mods, keys = [n for n in names if n in MODIFIERS], names[-1].split(",")
    steps = [{"key_code": KEY[m], "down": True, **({"after_ms": 2} if i else {})} for i, m in enumerate(mods)]
    lead = 10
    for _ in range(presses):
        for key in keys:
            steps.append({"key_code": KEY[key], "down": True, "after_ms": lead})
            steps += [{"key_code": KEY[key], "down": True, "after_ms": every_ms if i else delay_ms, "repeat": True} for i in range(repeats)]
            steps.append({"key_code": KEY[key], "down": False, "after_ms": 8})
            lead = max(gap_ms - 8, 1)
    return steps + [{"key_code": KEY[m], "down": False, "after_ms": 2} for m in reversed(mods)]


def send_keys(rpc, form, chord, key_window="shell", presses=1, gap_ms=250, repeats=0, delay_ms=0, every_ms=0):
    """Sends `chord` (as `key_steps`) in the launch's key form; returns what the app said, with `error` when the app
    refused it. `activate`: one `debug.key` sequence in the key window, played by the app's clock; the call waits for
    its end. `one-key`: each key-down is one `debug.key` call at its time by this script's clock."""
    if form == "activate":
        reply = rpc("debug.key", {"sequence": key_steps(chord, presses, gap_ms, repeats, delay_ms, every_ms), "key_window": key_window})
        reply = reply if isinstance(reply, dict) else {"error": f"debug.key: {reply}"}
        said = {k: reply[k] for k in ("base_s", "duration_ms", "scheduled", "key_window", "error") if reply.get(k) is not None}
        if "error" not in said and "base_s" not in said:
            said["error"] = f"debug.key gave no start time: {reply}"
        if "error" not in said:
            # sleep-ok: the app plays the sequence on its own clock for the duration_ms it answered; debug.key has no
            # read of a sequence's end, so this waits that stated length.
            time.sleep((said.get("duration_ms") or 0) / 1000 + 0.05)
        return said
    said = {"key_source": ONE_KEY, "key_window": key_window, "handled_by": [], "trace": [], "key_down_ms": []}
    if repeats:
        return {**said, "error": "a held key needs the key sequence of the `activate` launch form: this form has no repeat"}
    names, start = chord.split("+"), time.monotonic()
    mods = [{"opt": "option"}.get(n, n) for n in names if n in MODIFIERS]  # the app's names of them
    for i, key in enumerate(key for _ in range(presses) for key in names[-1].split(",")):
        time.sleep(max(0.0, start + i * gap_ms / 1000 - time.monotonic()))  # key-down to key-down, as the sequence
        said["key_down_ms"].append(round((time.monotonic() - start) * 1000, 1))  # when this call goes: late if the call before it was slow
        reply = rpc("debug.key", {"key": key, "modifiers": mods, **({"target": "page"} if key_window == "page" else {})})
        reply = reply if isinstance(reply, dict) else {"error": f"debug.key: {reply}"}
        said["handled_by"].append(f"{reply.get('handled_by')}: {reply.get('action')}")
        said["trace"] += [str(line)[:160] for line in (reply.get("trace") or [])[:6]]
        # `refused_action`: the app took the key for that action and the action did not run.
        error = reply.get("error") or (reply.get("refused_action") and f"the app did not run {reply['refused_action']}")
        if error:
            return {**said, "error": str(error)}
    return {**said, "duration_ms": round((time.monotonic() - start) * 1000, 1)}


def focus_word(rpc):
    """The `key_window` word for the next key sequence of the `activate` form, by one read of `debug.focus`: `page`
    when a Chromium page has the keys, else `shell`. The app shows such a page (a browser tab, a chat, the New Tab
    page) in a child window that has the keys while the page has focus, and it gives the keys back to that window
    when the shell window takes them with no click; so it refuses `shell` then (`the shell window did not become
    key`). The word thus follows the focus at each key: a Cmd-T moves the keys to the new tab's page. The read:
    `appkit.child_window_page` of the cmux window that is key, or of each window when none is (a page's window is).
    Returns (the word, None); for a read that failed: (`shell`, the words of the fault), so that the caller can say
    that no read gave the word."""
    focus = rpc("debug.focus")
    if not isinstance(focus, dict) or focus.get("error"):
        return "shell", f"debug.focus: {str(focus.get('error') if isinstance(focus, dict) else focus)[:120]}"
    windows = [w for w in focus.get("windows") or [] if isinstance(w, dict)]
    return ("page" if any((w.get("appkit") or {}).get("child_window_page") for w in [w for w in windows if w.get("is_key")] or windows) else "shell"), None


def key_refusal(said):
    """True when the app refused the `key_window` word of a send (KEY_REFUSALS). By a read of the app's source, it
    refuses the word before it posts a key of that call."""
    return any(text in str(said.get("error") or "") for text in KEY_REFUSALS)


def shell_try(word, said):
    """True when the keys of a `page` send can go to the shell window: the app refused the page's WINDOW, and no key
    went before that refusal (in the `one-key` form each key is one call: `key_down_ms` has the time of each call
    that went, the refused one also). After each other error the app can have the keys (a call that timed out):
    a second send would do the act 2 times, so there is none."""
    return word == "page" and key_refusal(said) and len(said.get("key_down_ms") or ()) <= 1


def refusal_words(word, said):
    """A refused send for `refused_as` and for a PREFLIGHT line: the word of the send, then the app's words."""
    return f"{word}: {str(said['error'])[:120]}"


def send_by_focus(rpc, chord, *more):
    """One key sequence of the `activate` form in the window that has the keys (`focus_word`). The read and the keys
    are 2 calls, and the app moves the keys to a new page in that time (directly after a Cmd-T). So when the app
    refuses the word with one of its 2 refusals of a key window (KEY_REFUSALS): ONE new read and ONE more send, and
    no wait. When the app refuses `page` at that second send also, the focus is on a page and the app finds no
    page window for it (a tab that is no Chromium child window, or 2 cmux windows): ONE last send in the shell
    window. So 3 sends at most, in that one case, and none after an error that is no refusal of a key window.
    Returns (what the app said of the last send, the word of that send, the refusals before it as a list of
    `<word>: <the app's words>`). What the app said gets `focus_not_read` when a read of the focus failed. `more`:
    the arguments of `send_keys` after the key window."""
    word, unread = focus_word(rpc)
    said, refusals = send_keys(rpc, "activate", chord, word, *more), []
    if key_refusal(said):
        refusals.append(refusal_words(word, said))
        word, again = focus_word(rpc)
        unread = unread or again
        said = send_keys(rpc, "activate", chord, word, *more)
        if shell_try(word, said):
            refusals.append(refusal_words(word, said))
            word = "shell"
            said = send_keys(rpc, "activate", chord, word, *more)
    if unread:
        said["focus_not_read"] = unread
    return said, word, refusals


def tries(said, refusals):
    """The end of a PREFLIGHT line of a key: the refusals before the send that the line is of, and a focus read
    that failed. "" for a key that had one send with a word from a read."""
    again = ""
    if len(refusals) == 1:
        again = f"; the second try, after the app refused the first one ({refusals[0]})"
    elif refusals:
        again = f"; the third try, in the shell window, after the app refused the word 2 times ({'; '.join(refusals)})"
    unread = said.get("focus_not_read")
    return again + (f"; the focus was not read ({unread}), so the word `shell` was sent" if unread else "")


def motion_reply(rpc, value=None):
    """The app's reply to `debug.motion`: `speed` with `value` when one is given (it sets the animation speed, in the
    app's memory only), else `read`. Each reply has the app's `speed` word and the fields of MOVES. {} for a reply
    that is no object."""
    reply = rpc("debug.motion", {"action": "speed", "value": value} if value else {"action": "read"})
    return reply if isinstance(reply, dict) else {}


def motion_spans(reply):
    """A `debug.motion` `stop` reply as fields of a film's row. `spans`: the name, the length and the start (ms from
    the record's start) of 60 spans at most that ended in the record: each span with the name `layout` (a pane
    motion), and the other spans while there is room, in the app's order. `spans_total`: how many the app gave;
    `spans_cut`: how many of them are not in the row; `speed_at_stop`: the app's speed word in that reply. Or
    `spans` = the words of a reply that has no span list."""
    if not isinstance(reply, dict) or not isinstance(reply.get("spans"), list):
        return {"spans": f"not read: {str(reply)[:160]}"}
    spans = [(index, span) for index, span in enumerate(reply["spans"]) if isinstance(span, dict)]
    layout = [index for index, span in spans if span.get("name") == "layout"][:60]
    kept = set(layout + [index for index, span in spans if span.get("name") != "layout"][:60 - len(layout)])
    return {"spans": [{k: span.get(k) for k in ("name", "ms", "at_ms")} for index, span in spans if index in kept],
            "spans_total": len(reply["spans"]), "spans_cut": len(reply["spans"]) - len(kept), "speed_at_stop": reply.get("speed")}


class NotKnown(RuntimeError):
    """A debug read of what is over the window failed, or its reply has no list."""


class NotMade(RuntimeError):
    """A check before the take refused the film. `stop`: no other film of this launch can be made."""

    def __init__(self, reason, stop=False):
        super().__init__(reason)
        self.stop = stop


def over_window(rpc):
    """What is over the app's window now, by the app's 3 debug reads: (each visible dialog, the overlays of each
    window, the messages on the screen, each refusal message so far). NotKnown for a read that failed, for a reply
    with no list (an older app) and for a reply that does not say it: a dialog with no `visible` word, no window (the
    app gives one entry for each window), a window with no list of its messages. The caller then cannot say that the
    window is clear."""
    def listed(method, field):
        reply = rpc(method)
        if not isinstance(reply, dict) or reply.get("error") or not isinstance(reply.get(field), list):
            raise NotKnown(f"{method} `{field}`: {str(reply)[:160]}")
        return reply
    dialogs = listed("debug.dialog", "dialogs")["dialogs"]
    for dialog in dialogs:
        if not isinstance(dialog, dict) or not isinstance(dialog.get("visible"), bool):
            raise NotKnown(f"debug.dialog `visible`: {str(dialog)[:160]}")
    dialogs, overlays, messages = [dialog for dialog in dialogs if dialog["visible"]], [], []
    windows = listed("debug.focus", "windows")["windows"]
    if not windows:
        raise NotKnown("debug.focus `windows`: the list has no window")
    for window in windows:
        found = (window.get("model") or {}).get("overlays") if isinstance(window, dict) else None
        if not isinstance(found, list):
            raise NotKnown(f"debug.focus `overlays`: {str(window)[:160]}")
        overlays += [str(name) for name in found]
    toast = listed("debug.toast", "windows")
    if not isinstance(toast.get("refusals"), list):
        raise NotKnown(f"debug.toast `refusals`: {str(toast)[:160]}")
    if not toast["windows"]:
        raise NotKnown("debug.toast `windows`: the list has no window")
    for window in toast["windows"]:
        found = window.get("toasts") if isinstance(window, dict) else None
        if not isinstance(found, list) or not all(isinstance(entry, dict) for entry in found):
            raise NotKnown(f"debug.toast `toasts`: {str(window)[:160]}")
        messages += [str(entry.get("message")) for entry in found]
    return dialogs, overlays, messages, [str(text) for text in toast["refusals"]]


def dialog_words(dialog):
    """A dialog for a row: its title and its lines, word for word."""
    return f"{dialog.get('title')}: {' '.join(str(line) for line in dialog.get('lines') or [])}"[:300]


def new_refusals(before, after):
    """The entries that the app added to its refusal list between 2 reads. The app keeps the last 100, so the first
    entries of `before` can be gone from `after`: the new ones are behind the longest end of `before` that `after`
    starts with. (With 100 equal entries before and after, a new equal one is not seen.)"""
    for gone in range(len(before) + 1):
        kept = len(before) - gone
        if after[:kept] == before[gone:]:
            return after[kept:]
    return list(after)


def act_check(spec):
    """The words of a row for the checks of this film's acts that the script makes after them."""
    change = spec.get("change", 0)
    checks = [f"the pane count ({change:+d})" if change else "the pane count"]
    checks += ["the zoomed panes"] if any(act[0] == "keys" and act[1] == ZOOM_CHORD for act in spec["acts"]) else []
    checks += ["the new pane before the close"] if ("tabs",) in spec["acts"] else []
    checks += [f"the tab count ({spec['tab_change']:+d})"] if spec.get("tab_change") else []
    checks += ["the `layout` spans"] if spec.get("layout") else []
    checks += [f"the new windows ({spec['windows']:+d})"] if spec.get("windows") else []
    return ACT_ONLY if checks == ["the pane count"] else "act check: the refusal list, the dialogs, " + ", ".join(checks)


def app_said(said):
    """What the app answered to the keys of one `send_keys` call, for a PREFLIGHT line. A key sequence plays after
    its call returns, so the app says of it only that it is scheduled."""
    if "handled_by" in said:
        return f"the app's reply to each key (handled_by: action) = {said['handled_by']}, trace = {said.get('trace') or []}"
    return "a key sequence, " + ", ".join(f"{k} = {said[k]}" for k in ("scheduled", "key_window", "duration_ms") if k in said)


def dry_run(rpc, chord):
    """What the app's key router would do with the first key of `chord` (`debug.key` with `dry_run`: nothing runs),
    for the FAILED line of a key sequence: the app says of a sequence only that it is scheduled."""
    names = chord.split("+")
    try:
        reply = rpc("debug.key", {"key": names[-1].split(",")[0], "modifiers": [{"opt": "option"}.get(n, n) for n in names if n in MODIFIERS], "dry_run": True})
    except Exception as error:  # noqa: BLE001  a fault of this read must not hide the fault that it is for
        reply = f"not read: {error!r}"
    return f"a dry run of the key (the key router's decision; nothing runs) = {(json.dumps(reply, default=str) if isinstance(reply, dict) else str(reply))[:400]}"


def label(act, zoom="key"):
    """The words of one act for the film's bar, or "" for a wait. With `zoom` = BY_ACTION the zoom key is not sent:
    the words say what makes the zoom."""
    if act[0] == "keys" and act[1] == ZOOM_CHORD and zoom == BY_ACTION:
        return f"action {ZOOM_ACTION} ({BY_ACTION})"
    if act[0] == "keys":
        _, chord, presses, _, hold = act
        names = chord.split("+")
        mods = "".join(n.capitalize() + "-" for n in names[:-1])
        said = " then ".join(mods + NAMES.get(k, k.capitalize()) for k in names[-1].split(","))
        return said + (f" x{presses}" if presses > 1 else "") + (" held" if hold == "tabs" else f" held {hold:g} s" if hold else "")
    if act[0] in ("action", "go"):
        return f"action {act[1] if act[0] == 'action' else 'goToWorkspace'} (no key)"
    return {"divider": "drag of a divider by a debug command", "tab": "drag of a tab by a debug command"}.get(act[0], "")


def redraw_program(asked):
    """(name, command line) of the program for a `redraw` pane: `asked`, or the first of htop, nvim that this host
    has, else the system's top."""
    path = os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"
    for name, tail in (("htop", " -d 5"), ("nvim", " -R /etc/services")):
        found = shutil.which(name, path=path)
        if found and asked in ("auto", name):
            return name, found + tail
    return "top", "/usr/bin/top -s 1"


def seed(app, count, live, url, deadline, out):
    """`count` workspaces by session_real.py `make` on the app's daemon, each with a terminal tab (parked, but for
    `live` of them) and a page tab at `url`: what the maker did, for the report."""
    command = [sys.executable, MAKER, "make", "--app-socket", app.socket, "--workspaces", str(count), "--terminals", str(count),
               "--agents", "0", "--no-agents", "--settle", "0", "--tabs", str(2 * count), "--panes", str(count),
               "--browser-tabs", str(count), "--browser-url", url, "--live-shells", str(live), "--out", os.path.join(out, "session.json")]
    began = time.monotonic()
    try:
        done = subprocess.run(command, check=False, timeout=deadline, capture_output=True, text=True)
        code, said = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as late:
        parts = [part.decode(errors="replace") if isinstance(part, bytes) else part or "" for part in (late.stdout, late.stderr)]
        code, said = f"not done in {deadline:.0f} s", "".join(parts)
    print(said[-4000:], flush=True)
    counted = re.findall(r"^made (\d+)/", said, re.M)
    return {"asked": count, "live_shells": live, "maker_exit": code, "maker_said_made": int(counted[-1]) if counted else 0,
            "seed_s": round(time.monotonic() - began, 1)}


class PreflightFailed(RuntimeError):
    pass


class LookNotShown(PreflightFailed):
    """The window does not show the look of `--window-look`: no other launch form (its config is the same), no film."""


class SecondInstance(PreflightFailed):
    """A second instance of the app runs after the LaunchServices open: no other launch form, no film."""


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
    of this launch. It raises SecondInstance with the line: the run ends there, and no film is made with an app on
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


def preflight(app, st, out, mbps, form, display):
    """One of each thing that a film needs, in a workspace of its own, each read back: `frames`, `record`, `new-tab`,
    `close-tab`, `split`, `zoom`, the keys in the launch's key form. Prints the state of the launch, then
    `PREFLIGHT <name> ok: <what was read>` for each, then returns (the display link's reply, what makes a zoom); the
    first that fails prints the app's words, `debug.focus` and the window's frame, and raises. The zoom does not
    raise: it is "key", else BY_ACTION (the key changed nothing and `action.run` did), else "none: <why>". PREFLIGHT_S
    at most for the checks that can end the launch; the settle wait and the zoom are after that bound and have their
    own (so a slow zoom costs only the films with a zoom)."""
    rpc, began, name = app.rpc, time.monotonic(), "launch"

    def wait(test, bound, step, cut=True):
        """`cut`: the bound ends with the preflight's PREFLIGHT_S."""
        return STRESS.wait(test, max(0.2, min(bound, began + PREFLIGHT_S - time.monotonic())) if cut else bound, step=step)

    def failed(said):
        late = f" (the preflight's {PREFLIGHT_S} s are over)" if name not in ("settle", "zoom") and time.monotonic() - began > PREFLIGHT_S else ""
        print(f"PREFLIGHT {name} FAILED: {str(said)[:1200]}{late}", flush=True)
        print("PREFLIGHT focus: " + json.dumps(rpc("debug.focus"))[:2000], flush=True)
        print("PREFLIGHT window: " + json.dumps(rpc("debug.window_frame", {}))[:600], flush=True)
        return f"{name}: {str(said)[:300]}"

    def fail(said):
        raise PreflightFailed(failed(said))

    def ok(said):
        print(f"PREFLIGHT {name} ok: {said}", flush=True)

    def key(chord, read, want, unit, must=True):
        """One chord as a film sends it; `read()` must become `want` in 10 s. Returns "" when it did; when it did
        not: raises with `must`, else prints the same lines and returns the fault."""
        before = read()
        said, _, refusals = send_by_focus(rpc, chord) if form == "activate" else (send_keys(rpc, form, chord, "shell"), "shell", [])
        again = tries(said, refusals)
        fault = said.get("error") or (not wait(lambda: read() == want(before), 10, 0.05, cut=must) and f"{unit} {before} -> {read()} in 10 s, not {want(before)}")
        if fault:
            fault = f"{fault}; {app_said(said)}{again}" + (f"; {dry_run(rpc, chord)}" if form == "activate" else "")
            return fail(fault) if must else failed(fault)
        ok(f"{unit} {before} -> {read()}; {app_said(said)}{again}")
        return ""

    focus = rpc("debug.focus")
    focus = focus if isinstance(focus, dict) else {}
    print(f"PREFLIGHT launch: activate={'yes' if form == 'activate' else 'no'} app_active={str(bool(focus.get('app_active'))).lower()} "
          f"key_window={focus.get('key_window') or 'none'} display={display}", flush=True)
    name = "frames"
    rpc("debug.frames", {"action": "start"})
    time.sleep(1.0)  # sleep-ok: the 1 s window of the app's display link that measures its frame rate
    link = rpc("debug.frames", {"action": "stop"})
    link = link if isinstance(link, dict) else {}
    if not link.get("frames"):
        fail(f"the display link gave no frame in 1 s: {link}")
    ok(f"frames {link.get('frames')}, p50 {link.get('p50_ms')} ms")
    workspace = st.new_workspace()
    if workspace:
        st.show(workspace)
    pane = workspace and wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 20, 0.05)
    shell = pane and next((t.get("id") for t in st.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
    name = "record"
    if not shell:
        fail(f"no new workspace with a terminal pane (workspace {workspace}, pane {pane})")
    st.focus_pane(pane)
    read = lambda: (lambda r: r if isinstance(r, dict) else {})(rpc("debug.motion", {"action": "record_read"}))
    started = rpc("debug.motion", {"action": "record_start", "path": os.path.join(out, "preflight.mov"), "seconds": 20, "mbps": mbps})
    if not isinstance(started, dict) or started.get("error"):
        fail(f"record_start: {started}")
    if not wait(lambda: read().get("capturing") or read().get("error"), 10, 0.1) or read().get("error"):
        fail(f"the recorder did not start to capture in 10 s: {read()}")
    st.send(shell, "echo preflight\r")  # a change of the screen: the recorder gets a frame only for one
    drawn = wait(lambda: read().get("complete"), 10, 0.1)
    rpc("debug.motion", {"action": "record_stop"})
    done = wait(lambda: (lambda r: r if r.get("written") or r.get("error") else None)(read()), 20, 0.25) or {}
    if not drawn or not done.get("frames") or done.get("error") or done.get("write_error"):
        fail(f"the recorder gave no frame of a screen that changed: {done or read()}")
    ok(f"frames {done.get('frames')}, complete {done.get('complete')}, {started.get('width')}x{started.get('height')}, movie {done.get('movie_status')}")
    tabs = lambda: len(st.tabs(workspace, pane))
    panes = lambda: len(st.panes(st.workspace(workspace)))
    zoomed = lambda: sum(1 for s in (st.workspace(workspace) or {}).get("screens") or [] if s.get("zoomed_pane"))
    for name, chord, count, want, unit in (
            ("new-tab", "cmd+t", tabs, lambda n: n + 1, "tabs"), ("close-tab", "cmd+w", tabs, lambda n: n - 1, "tabs"),
            ("split", "cmd+d", panes, lambda n: n + 1, "panes")):
        key(chord, count, want, unit)
    # The bound is for the checks above, which can end the launch. The settle wait and the zoom are after it.
    name, spent = "time", time.monotonic() - began
    if spent > PREFLIGHT_S:
        fail(f"each check before the zoom passed, in {spent:.0f} s")
    # A film zooms a layout that is made and settled. So the zoom key waits for the split's new pane: 2 reads with
    # the same panes, each with a tab, none of them the app's stand-in for a tab that the daemon does not have yet.
    name, waited = "settle", time.monotonic()
    shape = lambda: [(p.get("id"), [t.get("id") for t in p.get("tabs") or []]) for p in st.panes(st.workspace(workspace))]

    def still():
        one = shape()
        if not all(tabs and not any(str(t).startswith(STRESS.PROVISIONAL_TAB) for t in tabs) for _, tabs in one):
            return None
        time.sleep(0.3)  # sleep-ok: the spacing of the 2 reads of this stability check (it runs under `wait`)
        return one if shape() == one else None
    settled = wait(still, 15, 0.1, cut=False)
    print(f"PREFLIGHT settle {'ok' if settled else 'not reached in 15 s (the zoom key is sent now)'}: {len(shape())} panes, "
          f"{time.monotonic() - waited:.1f} s after the split" + ("" if settled else f"; the panes and their tabs = {shape()}"[:700]), flush=True)
    name, zoom = "zoom", "key"
    turn = lambda n: 0 if n else 1
    fault = key(ZOOM_CHORD, zoomed, turn, "zoomed panes", must=False) or key(ZOOM_CHORD, zoomed, turn, "zoomed panes", must=False)
    if fault:
        # The key changed nothing: the same motion by the action, on the pane that has the focus in this window.
        zoom, target = BY_ACTION, (st.window_showing(workspace) or {}).get("focused_pane")
        for _ in range(2):
            before = zoomed()
            reply = st.action(ZOOM_ACTION, target=f"pane:{target}" if target else None)
            refusal = isinstance(reply, dict) and reply.get("error")
            if refusal or not wait(lambda: zoomed() == turn(before), 10, 0.05, cut=False):
                unchanged = f"zoomed panes {before} -> {zoomed()} in 10 s, not {turn(before)}; the action's reply = {json.dumps(reply, default=str)[:300]}"
                zoom = "none: " + failed(f"by action.run also: {refusal or unchanged}; the key: {fault}")
                break
            ok(f"zoomed panes {before} -> {zoomed()}, {BY_ACTION}")
    st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
    st.made.clear()
    print(f"PREFLIGHT passed: frames, record, new-tab, close-tab, split in {spent:.0f} s; zoom = {zoom[:200]}", flush=True)
    return link, zoom


class Films:
    def __init__(self, app, opts, mock, form):
        self.app, self.opts, self.mock, self.form = app, opts, mock, form
        self.zoom = "key"  # the preflight's word: "key", BY_ACTION, or "none: <why>"
        self.speed_fault = ""  # the words of a film's end that did not give the animation speed back: for each row after it
        self.stop = ""  # why no other film of this launch can be made (a dialog or an overlay that stays over the window)
        self.session = []  # the workspaces that the session's maker made in this launch, in the app's order
        self.home = None  # in a film of the set-up `C`: (the app's Home workspace, the panes that it had before the film)
        self.st = STRESS.Stress(app.rpc)
        self.program = redraw_program(opts.program)
        self.main_window = next(iter(self.windows()), None)

    def left(self):
        return self.opts.deadline - time.monotonic()

    def windows(self):
        """The model key of each cmux window. By a read of the app's source, `debug.window.focus` takes that key; the
        layout reply's `id` is the window's public id, and the app answers it with `no window with that id`."""
        return {w.get("key") or w.get("id") for w in self.st.topology().get("windows") or []} - {None}

    def main_windows(self):
        """The app's windows of the kind `main` by ONE read of `debug.window_list`: {the window's number: (if the app
        says that it is on the screen (`visible`, not `occluded`, not `miniaturized`), its frame)}. A window whose
        entry does not say all 3 is not on the screen. NotKnown when the read gave no list."""
        reply = self.app.rpc("debug.window_list")
        found = reply.get("windows") if isinstance(reply, dict) else None
        if not isinstance(found, list) or not all(isinstance(window, dict) for window in found):
            raise NotKnown(f"the window list read gave no list: {str(reply)[:160]}")
        return {window.get("id"): (window.get("visible") is True and window.get("occluded") is False and window.get("miniaturized") is False,
                                   window.get("frame")) for window in found if window.get("kind") == "main"}

    def new_windows(self, wanted, had, clock):
        """Reads the app's window list until `wanted` windows that are not in `had` are on the screen, for WINDOW_S at
        most. For the row: `new_windows` = their count at the last read (`not read`: that read gave no list),
        `new_window_place` = the word of `window_place` from the frames of that same read, and `new_window_at_s` =
        the end of the read that had them, from the film's start."""
        seen = {}

        def read():
            seen.clear()  # the helper's `wait` takes a read that raises as `no value`
            found = self.main_windows()
            new = [frame for number, (shown, frame) in found.items() if shown and number not in had]
            seen.update(new_windows=len(new), new_window_place=window_place([found[number][1] for number in had if number in found], new))
            return len(new) >= wanted
        came = STRESS.wait(read, WINDOW_S, step=0.25)
        return {**(seen or {"new_windows": "not read"}), **({"new_window_at_s": round(time.monotonic() - clock, 3)} if came else {})}

    def chat(self, pane):
        """Waits for the chat page of `pane`, then starts its synthetic stream in a thread (the call ends with the
        stream); returns the thread's box."""
        ready = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and not r.get("error") else None)(
            self.app.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, 30)), 20, step=0.5)
        if not ready:
            last = self.app.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, 30)
            raise RuntimeError(f"the chat page was not ready in 20 s: {last}")
        box = {"reply": None}

        def run():
            box["reply"] = self.app.rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": self.opts.thread_rows,
                                                             "seconds": self.opts.stream_seconds}, self.opts.stream_seconds + 90)
        box["thread"] = threading.Thread(target=run, daemon=True)
        box["thread"].start()
        return box

    def chief(self, row):
        """The set-up `C`: no new workspace. The app itself puts the Chief's tab (a tab of the kind `conversation`) into
        its Home workspace, and no action opens one. So: the action `home.show`, then the pane with such a tab in the
        workspace that the window shows, with the focus; returns (workspace, [pane], []). A launch whose Home has no
        such tab gives no film: the fault's words have the tab kinds of each pane that the read found. A workspace of
        the session is never taken for the Home workspace."""
        st, seen = self.st, []
        row["panes"], row["dock"] = ["chief"], HOME_DOCK
        reply = st.action("home.show")
        if isinstance(reply, dict) and reply.get("error"):
            raise RuntimeError(f"the app refused home.show: {str(reply['error'])[:160]}")

        def found():
            for space in st.workspaces():
                if space["id"] in self.session or st.window_showing(space["id"]) is None:
                    continue
                panes = st.panes(st.workspace(space["id"]))
                seen[:] = [[tab.get("kind") for tab in pane.get("tabs") or []] for pane in panes]
                for pane in panes:
                    tab = next((tab for tab in pane.get("tabs") or [] if tab.get("kind") == "conversation"), None)
                    # The tab is the one that its pane shows (a pane with no word of its selected tab has 1 tab here).
                    if tab and pane.get("selected_tab", tab.get("id")) == tab.get("id"):
                        return space["id"], pane["id"], {p["id"] for p in panes}, tab.get("title")
            return None
        hit = STRESS.wait(found, SHOW_S, step=0.1)
        if not hit:
            raise RuntimeError(f"no tab of the kind `conversation` in the workspace that the window shows after home.show, in {SHOW_S} s "
                               f"(the tab kinds of each of its panes: {seen})")
        workspace, pane, had, row["chief_tab"] = hit
        self.home = (workspace, had)
        st.focus_pane(pane)
        self.settle(workspace)  # the Home workspace is on the screen, its layout still, before the take
        return workspace, [pane], []

    def settle(self, workspace):
        """Waits until the window shows `workspace` and its panes, their tabs (none of them the app's stand-in for a
        tab that the daemon does not have yet) and the focused pane read the same for --settle s (the programs,
        the pages and the streams' first rows come up meanwhile), for --settle + 20 s at most; logs when they did not."""
        st, quiet = self.st, max(self.opts.settle, 0.5)

        def shape():
            topology = st.topology()
            window = st.window_showing(workspace, topology)
            panes = st.panes(next((w for w in topology.get("workspaces") or [] if w.get("id") == workspace), None))
            tabs = [(p.get("id"), [t.get("id") for t in p.get("tabs") or []]) for p in panes]
            if not window or not tabs or any(str(t).startswith(STRESS.PROVISIONAL_TAB) for _, ids in tabs for t in ids):
                return None
            return json.dumps([window.get("focused_pane") or window.get("pane"), tabs], sort_keys=True)

        deadline, last, since = time.monotonic() + quiet + 20, None, time.monotonic()
        while time.monotonic() < deadline:
            try:
                now = shape()
            except Exception:  # noqa: BLE001 (the app may not answer yet)
                now = None
            if now is None or now != last:
                last, since = now, time.monotonic()
            elif time.monotonic() - since >= quiet:
                return True
            time.sleep(0.1)
        print(f"SETTLE {workspace}: the layout did not hold still for {quiet:g} s in {quiet + 20:g} s; the take starts now", flush=True)
        return False

    def build(self, spec, row):
        """A new workspace, shown, with the panes of the film's set-up; returns (workspace, pane ids, stream boxes)."""
        st, (layout, kinds) = self.st, SETUPS[spec["setup"]]
        if layout == "home":
            return self.chief(row)
        # With the page mock off no chat thread can stream: that pane is the product's New Tab page.
        kinds = row["panes"] = [kind if kind != "chat" or self.mock else "newtab" for kind in kinds]
        workspace = st.new_workspace()
        if not workspace:
            raise RuntimeError("no new workspace")
        st.show(workspace)
        first = STRESS.wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 30, step=0.05)
        if not first:
            raise RuntimeError("the new workspace has no pane")
        panes = [first]
        for index in range(1, len(kinds)):
            parent, verb = (panes[index - 2], "splitDown") if layout == "grid" and index >= 2 else (panes[-1], "splitRight")
            made = st.split(workspace, parent, verb)
            if not made:
                raise RuntimeError(f"{verb} made no pane: {st.refusals[-1:]}")
            panes.append(made)
        chats = []
        for pane, kind in zip(panes, kinds):
            shell = next((t.get("id") for t in st.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
            if kind in ("redraw", "stream") and shell:
                st.send(shell, (self.program[1] if kind == "redraw" else PING) + "\r")
            elif kind in ("page", "chat"):
                fallbacks = st.chat_fallbacks
                st.add_tab(workspace, pane, "chromium" if kind == "page" else "chat")
                if st.chat_fallbacks > fallbacks or not (st.made.get(pane) or [(kind, None)])[-1][1]:
                    raise RuntimeError(f"no {kind} tab: the app refused it or it did not come ({st.refusals[-1:]})")
                if shell:
                    st.action("closeTab", target=f"tab:{shell}", focus=False)
                if kind == "chat":
                    chats.append(pane)
            elif kind == "newtab":
                before = {t.get("id") for t in st.settled_tabs(workspace, pane)}
                reply = st.action("newTab.page", target=f"pane:{pane}")
                if not STRESS.wait(lambda: [t for t in st.tabs(workspace, pane) if t.get("id") not in before] or None, 20, step=0.1):
                    raise RuntimeError(f"no New Tab page in 20 s: {str(reply)[:160]}")
                if shell:
                    st.action("closeTab", target=f"tab:{shell}", focus=False)
            elif kind in APP_PAGES:
                action, page = APP_PAGES[kind]
                st.focus_pane(pane)  # `home.tab` and `openSettings` open in the pane with the focus
                before = {t.get("id") for t in st.settled_tabs(workspace, pane)}
                if kind == "markdown":
                    path = os.path.join(self.opts.out, "pane-motion-films-page.md")
                    with open(path, "w") as f:
                        f.write(MARKDOWN)
                    reply = st.action(action, {"path": path}, target=f"pane:{pane}")
                else:
                    reply = st.action(action)
                # The layout gives each tab's kind and, for one of the app's pages, the page's id: no film of a pane
                # that shows another page.
                if not STRESS.wait(lambda: [t for t in st.tabs(workspace, pane) if t.get("id") not in before and t.get("page") == page] or None, 20, step=0.1):
                    raise RuntimeError(f"no tab of the page `{page}` in the pane in 20 s after the action {action}; the app's reply: {str(reply)[:160]}; "
                                       f"the pane's tabs (kind, page): {[(t.get('kind'), t.get('page')) for t in st.tabs(workspace, pane)]}")
                row.setdefault("pages", []).append(page)
                if shell:
                    st.action("closeTab", target=f"tab:{shell}", focus=False)
        row["dock"] = "not asked"
        if self.opts.dock and spec.get("dock", True):
            # One more shell pane, docked as a column (the app's default edge and mode). A dock that the app refuses,
            # or that the snapshot does not show as a dock, is closed again: the film then has no docked column.
            extra = st.split(workspace, panes[-1], "splitRight")
            reply = st.action("column.dock", target=f"pane:{extra}", focus=False) if extra else {"error": "no pane"}
            docked = extra and STRESS.wait(lambda: extra not in [p["id"] for p in st.panes(st.workspace(workspace))], 5, step=0.1)
            refusal = str(reply.get("error") if isinstance(reply, dict) else reply)[:120]
            row["dock"] = "a docked column" if docked else f"none: {refusal}"
            if extra and not docked:
                first_tab = (st.tabs(workspace, extra) or [{}])[0].get("id")
                st.action("closeTab", target=f"tab:{first_tab}", focus=False)
        focus = panes[spec.get("focus", 0)]
        st.focus_pane(focus)
        for _ in range(spec.get("tabs", 0)):
            st.add_tab(workspace, focus, "terminal")
        streams = [self.chat(pane) for pane in chats]
        self.settle(workspace)  # the workspace is shown, its panes and tabs made and still, before the take
        failed = [box["reply"] for box in streams if isinstance(box["reply"], dict) and box["reply"].get("error")]
        if failed:
            raise RuntimeError(f"the chat page did not stream: {failed[0]}")
        return workspace, panes, streams

    def drag(self, points):
        """One pointer drag through `points`: one `debug.mouse` request for each step, paced by this script; returns
        the steps asked and what the app's input journal has of them."""
        rpc, last = self.app.rpc, points[0]
        rpc("debug.journal", {"clear": True})
        rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": last[0], "to_y": last[1], "steps": 1, "release": False})
        for index, point in enumerate(points[1:], 1):
            rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": point[0], "to_y": point[1], "steps": 1,
                                "press": False, "release": index == len(points) - 1})
            last = point
            time.sleep(1 / DRAG_RATE)  # the pointer's pace, not a wait for a result
        entries = [e for e in (rpc("debug.journal", {"last": 2000}) or {}).get("entries") or [] if "drag" in json.dumps(e.get("kind"))]
        span = (entries[-1].get("uptimeNanos", 0) - entries[0].get("uptimeNanos", 0)) / 1e9 if len(entries) > 1 else 0
        return {"steps_asked": len(points) - 1, "rate_asked": DRAG_RATE, "journal_steps": len(entries),
                "journal_steps_per_s": round((len(entries) - 1) / span, 1) if span > 0 else None}

    def pointer(self, kind, panes):
        """The points of a drag: `divider` = the first divider, slow down and right, then 4 fast swings; `tab` = the
        first tab pill to the last pane."""
        line = lambda a, b, n: [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(1, n + 1)]
        at = lambda params: (lambda r: (r["x"], r["y"]) if isinstance(r, dict) and "x" in r else None)(self.app.rpc("debug.mouse", {"action": "move", **params}))
        if kind == "divider":
            start = at({"divider": "first"})
            if not start:
                raise RuntimeError("debug.mouse found no divider")
            far, near = (start[0] + 160, start[1] + 100), (start[0] - 80, start[1] - 50)
            return [start] + line(start, far, DRAG_RATE) + [p for _ in range(2) for p in line(far, near, 12) + line(near, far, 12)]
        pills = [p["pill"] for w in (self.app.rpc("debug.pane_chrome") or {}).get("windows") or [] for p in w.get("panes") or [] if p.get("pill")]
        goal = at({"pane": panes[-1]})
        if not pills or not goal:
            raise RuntimeError("no tab pill or no goal pane for the drag")
        start = (pills[0][0] + pills[0][2] / 2, pills[0][1] + pills[0][3] / 2)
        return [start] + line(start, goal, int(DRAG_RATE * 0.6))

    def layout(self, workspace):
        """(the pane count, the count of zoomed panes) of `workspace` now, by ONE read of the layout. NotKnown when the
        read gave no workspace: the session helper gives None for a read that failed and for a workspace that is gone,
        and that is no count of 0. NotKnown also for a workspace with no pane: a workspace has 1 pane or more."""
        found = self.st.workspace(workspace)
        if not isinstance(found, dict):
            raise NotKnown("the layout read gave no workspace")
        panes = len(self.st.panes(found))
        if not panes:
            raise NotKnown("the layout read gave no pane of the workspace")
        return panes, sum(1 for screen in found.get("screens") or [] if screen.get("zoomed_pane"))

    def counts(self, workspace):
        """As `layout`, with `not read` in the place of each count when the read gave no workspace."""
        try:
            return self.layout(workspace)
        except NotKnown:
            return "not read", "not read"

    def aside(self, name, row):
        """The movie of a film that is not `made` gets a name that says so: `<id>.not-made.mov`, and its frame file
        with it. The step's artifact has each movie of the out folder, and a person who opens it has no row beside
        it. `take_file` in the row = the movie's name now."""
        old, new = (os.path.join(self.opts.out, name + mark + ".mov") for mark in ("", ".not-made"))
        if not os.path.exists(old):
            return
        try:
            os.replace(old, new)
            if os.path.exists(old + ".frames.json"):
                os.replace(old + ".frames.json", new + ".frames.json")
        except OSError as error:
            row["take_file_fault"] = f"the name of the movie or of its frame file was not changed: {error}"[:300]
        row["take_file"] = os.path.basename(new if os.path.exists(new) else old)

    def play(self, acts, workspace, panes, focus, key_window, clock, checks=False):
        """Runs `acts`; returns one row for each act that is not a wait. With `checks` (the acts of the film itself):
        the row of a zoom key gets the count of zoomed panes (`zoomed_after`) by a read at the end of the pause after
        it, directly before the key that goes back; and a close after a split is not sent when the pane with the focus
        is not a new pane (`not_sent` in the row of the read, and no act after it runs)."""
        rows, zoom_row = [], None
        for act in acts:
            if act[0] == "wait":
                time.sleep(act[1])  # the pause between 2 acts of the film
                continue
            zoom_key = checks and act[0] == "keys" and act[1] == ZOOM_CHORD and act[2] == 1
            if zoom_key and zoom_row is not None:
                zoom_row["zoomed_after"], zoom_row, zoom_key = self.counts(workspace)[1], None, False
            row = {"label": label(act, self.zoom), "at_s": round(time.monotonic() - clock, 3)}
            if act[0] == "keys" and act[1] == ZOOM_CHORD and self.zoom == BY_ACTION:
                # The preflight's zoom key changed nothing in this launch: the zoom of the film's focused pane by the action.
                reply = self.st.action(ZOOM_ACTION, target=f"pane:{focus}")
                row["zoom"] = BY_ACTION
                if isinstance(reply, dict) and reply.get("error"):
                    row["error"] = str(reply["error"])[:160]
            elif act[0] == "keys":
                _, chord, presses, gap, hold = act
                # "tabs": the key-down and its repeats close all but 2 tabs of the pane, so the pane stays.
                delay, every = self.opts.repeat_delay_ms, max(self.opts.repeat_ms, 1)
                held = len(self.st.tabs(workspace, focus)) if hold == "tabs" else None
                if held == 0:  # a pane has 1 tab or more: no tab = a read that failed, and 1 repeat would be a guess
                    raise NotMade("the tab read gave no tab of the pane: no count for the held close")
                repeats = max(1, held - 3) if hold == "tabs" else max(1, 1 + int((hold * 1000 - delay) / every)) if hold else 0
                more = (presses, gap, repeats, delay, every)
                if self.form == "activate":
                    # The window that has the keys now. A word that the app refuses gets ONE new read and ONE more
                    # send; a `page` word that it refuses again gets ONE last send in the shell window.
                    said, _, refusals = send_by_focus(self.app.rpc, chord, *more)
                else:
                    refusals = []
                    said = send_keys(self.app.rpc, self.form, chord, key_window, *more)  # the word of the film's set-up
                    if shell_try(key_window, said):
                        # The app refused the page's window before a key went: ONE send in the shell window.
                        refusals.append(refusal_words(key_window, said))
                        said = send_keys(self.app.rpc, self.form, chord, "shell", *more)
                # No send after another error: the app can have the keys of a send that timed out.
                if refusals:
                    row["refused_as"] = refusals
                if presses > 1:
                    row["gap_asked_ms"] = gap  # from key-down to key-down, as asked: the row has no true gap
                row.update(said)
            elif act[0] == "action":
                reply = self.st.action(act[1], target=f"workspace:{workspace}" if act[2] == "workspace" else None)
                if isinstance(reply, dict) and reply.get("error"):
                    row["error"] = str(reply["error"])[:160]
            elif act[0] == "go":
                # No key: a key of Command and a number shows a row of the sidebar, not a workspace of the session.
                row["workspace_of_the_session"], target = act[1] + 1, self.session[act[1]]
                reply = self.st.action("goToWorkspace", {"workspace": target})
                if isinstance(reply, dict) and reply.get("error"):
                    row["error"] = str(reply["error"])[:160]
                elif not STRESS.wait(lambda: self.st.window_showing(target) is not None, SHOW_S, step=0.05):
                    raise NotMade(("" if checks else "before the take: ") + f"the window did not show the workspace {act[1] + 1} of the session "
                                  f"in {SHOW_S} s after the action goToWorkspace")
            elif act[0] == "show":
                self.st.show(workspace)
                self.st.focus_pane(focus)
                continue
            elif act[0] == "tabs":
                # No act of the film: which pane has the focus now (the pane that the next close takes), if it is a
                # pane that the film's set-up did not make (`new_pane`), the layout's kind of each of its tabs, and if
                # one of them is the app's stand-in for a tab that the daemon does not have yet (`provisional`).
                pane = (self.st.window_showing(workspace) or {}).get("focused_pane")
                tabs = self.st.tabs(workspace, pane) if pane else None
                row.update(label="read: the tabs of the pane with the focus", focused_pane=pane, new_pane=pane not in panes if pane else None,
                           tab_kinds=None if tabs is None else [tab.get("kind") for tab in tabs],
                           provisional=None if tabs is None else any(str(tab.get("id") or "").startswith(STRESS.PROVISIONAL_TAB) for tab in tabs))
                if checks and row["new_pane"] is not True:
                    # The close would take a pane of the set-up, and the app asks before it closes a terminal with a program.
                    rows.append({**row, "not_sent": NO_NEW_PANE})
                    break
            else:
                row["drag"] = self.drag(self.pointer(act[0], panes))
            zoom_row = row if zoom_key else zoom_row
            rows.append(row)
        return rows

    def clear(self, row):
        """The check before a take: nothing is over the app's window. Returns the app's refusal list of now. NotMade
        for a visible dialog or an overlay (with `stop`: it stays over each later film of the launch), for a message
        that is on the screen after OVERLAY_S more seconds of reads, and for a read that says nothing (in those
        seconds too: the helper's `wait` takes a read that raises as `no value`, so the last read's fault is kept)."""
        failed = []

        def again():
            try:
                now = over_window(self.app.rpc)
            except Exception as error:  # noqa: BLE001  a read that failed is not `the message is still there`
                failed[:] = [error]
                return None
            failed.clear()
            return None if now[2] else now
        try:
            over = over_window(self.app.rpc)
            if over[2] and not over[0] and not over[1]:
                row["message_waited"] = over[2]  # a message goes by itself: the script closes none
                over = STRESS.wait(again, OVERLAY_S, step=0.25)
                if not over and failed:
                    raise NotMade(f"before the take: the tool does not know what is over the window (a read failed in the wait for a message): {failed[0]}")
                if not over:
                    raise NotMade(f"before the take: a message stayed on the screen for {OVERLAY_S} s: {'; '.join(row['message_waited'])}")
        except NotKnown as error:
            raise NotMade(f"before the take: the tool does not know what is over the window: {error}") from error
        dialogs, overlays, _, refusals = over
        found = [f"a dialog was open: {dialog_words(dialog)}" for dialog in dialogs] + ([f"an overlay was open: {', '.join(overlays)}"] if overlays else [])
        if found:
            raise NotMade("before the take: " + "; ".join(found), stop=True)
        return refusals

    def unmade(self, spec, row, refusals):
        """The checks after the acts of a film whose movie is written: each reason why the row cannot say `made`
        ([] = none). `refusals`: the app's refusal list before the take. A dialog that the film opened gets ONE Cancel
        (`dialog` in the row); if the app does not take it, the launch stops."""
        faults = [act["not_sent"] for act in row["acts"] if act.get("not_sent")]
        try:
            dialogs, overlays, _, after = over_window(self.app.rpc)
        except NotKnown as error:
            dialogs, overlays, after = [], [], refusals
            faults.append(f"after the acts the tool does not know what is over the window: {error}")
        faults += [f"the app refused in the film: {message}" for message in new_refusals(refusals, after)]
        faults += [f"the app asked in the film: {dialog_words(dialog)}" for dialog in dialogs]
        faults += [f"the app showed an overlay in the film: {', '.join(overlays)}"] if overlays else []
        change = spec.get("change", 0)
        if row["panes_after"] == "not read":
            faults.append("the pane count after the acts was not read")
        elif row["panes_after"] - row["panes_before"] != change:
            faults.append(f"the pane count went from {row['panes_before']} to {row['panes_after']}: the film's acts make a change of "
                          + (f"{change:+d}" if change else "0"))
        if row.get("tabs_after") == "not read":
            faults.append("the tab count of the pane after the acts was not read")
        elif "tabs_before" in row and row["tabs_after"] - row["tabs_before"] != spec["tab_change"]:
            faults.append(f"the tab count of the pane went from {row['tabs_before']} to {row['tabs_after']}: the film's acts make a change of "
                          f"{spec['tab_change']:+d}")
        faults += [f"the zoomed panes after the act `{act['label']}` were not read" if act["zoomed_after"] == "not read" else
                   f"{act['zoomed_after']} zoomed panes after the act `{act['label']}`, not 1" for act in row["acts"] if act.get("zoomed_after", 1) != 1]
        if row.get("zoomed_end") == "not read":
            faults.append("the zoomed panes at the film's end were not read")
        elif row.get("zoomed_end"):
            faults.append(f"{row['zoomed_end']} zoomed panes at the film's end, not 0")
        if spec.get("windows") and row["new_windows"] == "not read":
            faults.append("the window list after the acts was not read")
        elif spec.get("windows") and row["new_windows"] != spec["windows"]:
            faults.append(f"{row['new_windows']} new windows of the kind `main` on the screen by the app's window list in {WINDOW_S} s after "
                          f"the acts: the film's acts make {spec['windows']}")
        elif spec.get("windows") and row["new_window_place"].startswith(OUT_OF_THE_RECTANGLE):
            faults.append(row["new_window_place"])
        if spec.get("windows") and row["take_s"] > TAKE_S - 1:  # 1 s: the recorder's clock started before this script read `capturing`
            faults.append(f"the take was {row['take_s']:g} s long, and the recorder ends by itself after {TAKE_S} s: the film's end is not in the movie")
        row["layout_spans"] = "not recorded"  # a film with no speed has no span record
        if spec.get("layout"):
            (low, high), spans = spec["layout"], row.get("spans")
            row["layout_spans"] = sum(1 for span in spans if span.get("name") == "layout") if isinstance(spans, list) else "not read"
            if isinstance(spans, list):  # a motion that is at rest in its first frame is a span too: the time of each says it
                row["layout_ms"] = [span.get("ms") for span in spans if span.get("name") == "layout"]
            if row["layout_spans"] == "not read" or not low <= row["layout_spans"] <= high:
                faults.append(f"{row['layout_spans']} `layout` spans in the span record: the film's acts make {low if low == high else f'{low} or {high}'}")
        if dialogs:
            words = dialog_words(dialogs[-1])
            reply = self.app.rpc("debug.dialog", {"id": dialogs[-1].get("id"), "dismiss": True})
            if isinstance(reply, dict) and reply.get("dismissed") is True:
                row["dialog"] = f"the tool sent Cancel: {words}"
            else:
                row["dialog"] = f"the tool sent Cancel, and the app did not take it: {words}"
                self.stop = f"the app did not take the Cancel of its dialog ({words})"
        return faults

    def take(self, spec):
        """One film: the row for films.json."""
        st, rpc, opts = self.st, self.app.rpc, self.opts
        zooms = any(act[0] == "keys" and act[1] == ZOOM_CHORD for part in ("pre", "acts", "post") for act in spec.get(part, ()))
        zoom_acts = any(act[0] == "keys" and act[1] == ZOOM_CHORD for act in spec["acts"])
        row = {"id": spec["id"], "title": spec["title"], "setup": spec["setup"], "status": "not_run", "crop": spec.get("crop", "window"),
               "keys": ", ".join(filter(None, (label(a, self.zoom) for a in spec["acts"]))), "agent_page_mock": self.mock, "launch_form": self.form,
               **({"zoom": self.zoom[:400]} if zooms else {}), **({"speed_fault": self.speed_fault} if self.speed_fault else {})}
        # A film with a speed: the speed is set and read back before the set-up, and the app records the film's motions.
        speed, before, traced, recorded = spec.get("speed"), None, False, False
        turned = any(act[0] == "keys" and act[1] == ZOOM_CHORD and act[2] > 1 for act in spec["acts"])
        workspaces, windows = {w["id"] for w in st.workspaces()}, self.windows()
        try:
            if self.left() < 90:
                raise RuntimeError("no time left in the step")
            if zooms and self.zoom not in ("key", BY_ACTION):
                raise RuntimeError(f"the preflight's zoom changed nothing, by the key and by action.run: {self.zoom}")
            if turned and self.zoom != "key":
                raise RuntimeError(f"the turned zoom is 2 zoom keys with a gap, and this launch makes a zoom by the action, not by a key: {self.zoom}")
            if spec["setup"] in MOCK_SETUPS and not self.mock:
                raise RuntimeError("this launch has the page mock off: a chat thread streams only under the mock")
            if len(self.session) < 2 and any(act[0] == "go" for part in ("pre", "acts", "post") for act in spec.get(part, ())):
                raise RuntimeError(f"the film shows 2 workspaces of the session, and this launch has {len(self.session)} (the workspaces "
                                   "that the app listed after the session's maker and not before it)")
            if speed:
                had = motion_reply(rpc).get("speed")
                row["speed_before"], before = had or NOT_READ, had or "fast"
                said = motion_reply(rpc, speed)
                off = said.get("disabled_categories")
                panes_off = isinstance(off, list) and "panes" in off  # the category of each pane motion
                row.update(speed=said.get("speed"), source_ms={name: SOURCE_MS[speed][name] for name in spec.get("springs", ())},
                           **{name: said.get(name) for name in MOVES}, disabled_categories=off)
                if row["speed"] != speed:
                    raise RuntimeError(f"the app did not take the animation speed `{speed}`: its reply says `{row['speed']}`")
                # Reduce Motion, the master switch, the pane switch or the category `panes` off: a pane motion is then
                # one frame at each speed. A reply with none of the fields (an older app) stops no film.
                if said.get("reduce_motion") is True or said.get("animations_enabled") is False or said.get("pane_animations") is False or panes_off:
                    names = MOVES + (("disabled_categories",) if panes_off else ())
                    raise RuntimeError(f"{STILL}: " + ", ".join(f"{name} = {json.dumps(said.get(name))}" for name in names))
            workspace, panes, streams = self.build(spec, row)
            focus = panes[spec.get("focus", 0)]
            # A person's key on a page goes through the page's own window: the film's keys take that path when the
            # focused pane shows a Chromium page. This word of the set-up is for the `one-key` form; in the `activate`
            # form each key sequence gets its word from the focus at that time (`focus_word`).
            key_window = "page" if SETUPS[spec["setup"]][1][spec.get("focus", 0)] == "page" else "shell"
            self.refused(self.play(spec.get("pre", ()), workspace, panes, focus, key_window, time.monotonic()))
            refusals = self.clear(row)  # nothing is over the window: no dialog, no overlay, no message
            try:
                row["panes_before"] = self.layout(workspace)[0]
            except NotKnown as error:  # no count: 0 panes before and 0 after would fit a film whose acts change no count
                raise NotMade(f"before the take: {error}") from error
            if spec.get("tab_change"):
                tabs = len(st.tabs(workspace, focus))  # a pane has 1 tab or more: no tab = a read that failed
                if not tabs:
                    raise NotMade("before the take: the tab read gave no tab of the pane")
                row["tabs_before"] = tabs
            if spec.get("windows"):
                try:
                    had = set(self.main_windows())  # each `main` window of now, on the screen or not
                except NotKnown as error:  # no list: the tool then cannot say which window is new
                    raise NotMade(f"before the take: {error}") from error
            started = rpc("debug.motion", {"action": "record_start", "path": os.path.join(opts.out, spec["id"] + ".mov"), "seconds": TAKE_S, "mbps": opts.mbps})
            if not isinstance(started, dict) or started.get("error"):
                raise RuntimeError(f"record_start: {started}")
            recorded = True
            try:
                state = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("capturing") or r.get("error")) else None)(
                    rpc("debug.motion", {"action": "record_read"})), 10, step=0.1) or {}
                if not state.get("capturing"):
                    raise RuntimeError(f"the recorder did not start to capture: {state.get('error') or 'no word in 10 s'}")
                if speed:
                    traced = True  # before the call: a call that fails or is interrupted still gets its `stop`
                    rpc("debug.motion", {"action": "start"})
                clock = time.monotonic()
                time.sleep(LEAD_S)  # sleep-ok: the film's still lead (LEAD_S of the window before the first act)
                row["acts"] = self.play(spec["acts"], workspace, panes, focus, key_window, clock, checks=True)
                self.refused(row["acts"])
                if spec.get("windows"):
                    row.update(self.new_windows(spec["windows"], had, clock))  # the film's tail starts when the app has the window
                # sleep-ok: the film's tail and minimum length (the recording window after the last act)
                time.sleep(max(spec.get("tail", 1.5), MIN_FILM_S - (time.monotonic() - clock)))
                row["take_s"] = round(time.monotonic() - clock, 3)
            finally:
                if traced:
                    row.update(motion_spans(rpc("debug.motion", {"action": "stop"})))
                rpc("debug.motion", {"action": "record_stop"})
                read = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("written") or r.get("error")) else None)(
                    rpc("debug.motion", {"action": "record_read"})), 60, step=0.25) or {"error": "the movie was not written in 60 s"}
            row["panes_after"], zoomed_end = self.counts(workspace)  # ONE read; `not read` is not a count of 0
            if spec.get("tab_change"):
                row["tabs_after"] = len(st.tabs(workspace, focus)) or "not read"
            if zoom_acts:
                row["zoomed_end"] = zoomed_end
            row["streams"] = ["still streamed at the film's end" if box["thread"].is_alive() else f"ended before the film's end: {str(box['reply'])[:200]}" for box in streams]
            row["recorder"] = {k: started.get(k) for k in ("width", "height", "scale", "rows", "columns", "filter", "source_rect")}
            row["recorder"].update({k: read.get(k) for k in ("frames", "first_t", "last_t", "complete", "stopped_by", "movie_status", "write_error", "error")
                                    if read.get(k) is not None})
            if not read.get("frames") or read.get("error"):
                raise RuntimeError(f"the recorder gave no movie: frames {read.get('frames')}, {read.get('error') or read.get('write_error')}")
            span = (read.get("last_t") or 0) - (read.get("first_t") or 0)
            # The mean over the whole take, still parts too: the true rate of a motion is in the frames.json times.
            row.update(mean_frames_per_s=round((read["frames"] - 1) / span, 2) if span > 0 else None, act_check=act_check(spec))
            # The row says `made` only after the checks of the acts. A film that they refuse keeps its movie under
            # another name (`take_file`, set at this film's end): it shows what the app did, and it is not in `file`.
            faults = self.unmade(spec, row, refusals)
            if faults:
                row.update(status="not_made", reason="; ".join(faults)[:800])
            else:
                row.update(status=MOVIE_NOT_CHECKED if spec.get("windows") else "made", file=spec["id"] + ".mov")
            self.play(spec.get("post", ()), workspace, panes, focus, key_window, time.monotonic())
        except NotMade as error:  # a check before the take (no movie), or a read for an act that gave no count
            row.update(status="not_made", reason=str(error)[:800])
            self.stop = str(error)[:800] if error.stop else self.stop
        except Exception as error:  # noqa: BLE001  one film's fault must not stop the other films
            traceback.print_exc()
            row["reason"] = str(error)[:400]
        finally:
            if before:
                row["speed_after"] = motion_reply(rpc, before).get("speed")  # the speed that the app had before this film
                if row["speed_after"] != before:
                    self.speed_fault = row["speed_fault"] = (f"the animation speed did not go back to `{before}` after the film {spec['id']}: "
                                                             f"the app says `{row['speed_after']}`")
            if recorded and row["status"] not in ("made", MOVIE_NOT_CHECKED):
                self.aside(spec["id"], row)
            row["left_open"] = self.restore(workspaces, windows)
        print("PANE-FILM " + json.dumps(row), flush=True)
        return row

    @staticmethod
    def refused(rows):
        """A key or an action that the app refused: the film has no motion of that act, so it is not a film of it."""
        for row in rows:
            if row.get("error"):
                raise RuntimeError(f"the app refused {row['label']}: {row['error']}")

    def restore(self, workspaces, windows):
        """Closes each window and each workspace that the film made; returns what it did not close. A window is closed
        only when a read of the layout after the close does not have it."""
        left, sent, seen = [], set(), [None]
        for window in self.windows() - windows:
            front = self.app.rpc("debug.window.focus", {"window": window}) or {}
            if window in (front.get("key"), front.get("front")):
                reply = self.st.action("closeWindow")
                if isinstance(reply, dict) and reply.get("error"):
                    left.append(f"a window ({str(reply['error'])[:80]})")
                else:
                    sent.add(window)
            else:
                left.append(f"a window ({str(front.get('error') or 'it did not come to the front')[:80]})")

        def closed():
            seen[0] = None  # the helper's `wait` takes a read that raises as `no value`
            seen[0] = self.windows() & sent
            return not seen[0]
        if sent and not STRESS.wait(closed, CLOSE_S, step=0.1):
            left += ["a window (the layout after closeWindow was not read)"] if seen[0] is None else [
                f"a window (still in the layout {CLOSE_S} s after closeWindow)" for _ in seen[0]]
        if self.windows() != windows and self.main_window:
            self.app.rpc("debug.window.focus", {"window": self.main_window})
        for workspace in [w["id"] for w in self.st.workspaces() if w["id"] not in workspaces]:
            reply = self.st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
            if isinstance(reply, dict) and reply.get("error"):
                left.append(f"a workspace ({str(reply['error'])[:80]})")
        if self.home:
            # No film closes the app's Home workspace: a zoom that a film left is taken back, and each pane that a film
            # left (a split whose close was not sent) is closed tab by tab.
            (workspace, had), self.home = self.home, None
            found = self.st.workspace(workspace) or {}
            replies = [self.st.action(ZOOM_ACTION, target=f"pane:{screen['zoomed_pane']}", focus=False)
                       for screen in found.get("screens") or [] if screen.get("zoomed_pane")]
            replies += [self.st.action("closeTab", target=f"tab:{tab.get('id')}", focus=False)
                        for pane in self.st.panes(found) if pane.get("id") not in had for tab in pane.get("tabs") or []]
            left += [f"a pane or a zoom of the Home workspace ({str(reply['error'])[:80]})" for reply in replies if isinstance(reply, dict) and reply.get("error")]
        self.st.made.clear()
        return left


def build_facts(path):
    """The report's `build`: the entry script's read of the reload's log (build-flags.py), or why there is none."""
    if not path:
        return {"not_read": "no --build file: the entry script gives it"}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as error:
        return {"not_read": f"{path}: {error!r}"}
    return data if isinstance(data, dict) else {"not_read": f"{path}: not a JSON object"}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", help="a bench `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/pane-motion-films")
    parser.add_argument("--films", default="kinds", help="film ids with commas, or kinds, mixed, plist, extra, cap, pages, close, all, list")
    parser.add_argument("--workspaces", type=int, default=24, help="the size of the session (0: no maker call)")
    parser.add_argument("--live-shells", type=int, default=4, help="terminals of the session that keep a shell")
    parser.add_argument("--page-url", default="http://127.0.0.1:9/", help="the address of each page tab of the session")
    parser.add_argument("--seed-deadline", type=float, default=900.0, help="seconds for the session's maker")
    parser.add_argument("--pinned", type=int, default=3, help="workspaces of the session that get a pin")
    parser.add_argument("--dock", type=int, default=1, help="1: each film's window has one more pane as a docked column")
    parser.add_argument("--chat-mock", default="auto", choices=("auto", "0", "1"),
                        help="the agent pages' in-page mock: auto = off, then a second launch with it on for the A- and M- films; 0 or 1 = one launch")
    parser.add_argument("--program", default="auto", help="the program of a `redraw` pane: auto, htop, nvim, top")
    parser.add_argument("--mbps", type=float, default=60, help="the recorder's bit rate")
    parser.add_argument("--repeat-delay-ms", type=float, default=375, help="a held key's first repeat (the default is macOS's own default setting)")
    parser.add_argument("--repeat-ms", type=float, default=90, help="a held key's repeat interval (the default is macOS's own default setting)")
    parser.add_argument("--thread-rows", type=int, default=2000, help="rows of a chat pane's thread before it streams")
    parser.add_argument("--stream-seconds", type=float, default=25, help="how long a chat pane streams")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds a film's set-up must hold still (window, panes, tabs) before its take")
    parser.add_argument("--launch-form", default="auto", choices=tuple(LAUNCH_FORMS),
                        help="activate: launch without CMUX_NEXT_NO_ACTIVATE (the app takes the keyboard, as a person's does), the keys as "
                             "sequences in the key window; one-key: the launcher's launch, each key-down one call; auto: activate, then one-key")
    parser.add_argument("--display", default="real", help="what the entry script says of the display, for the preflight's first line")
    parser.add_argument("--budget", type=float, default=0, help="seconds for the whole run; a film with no time left is not_run (0: no bound)")
    parser.add_argument("--build", help="the JSON of build-flags.py: the form of the app's build, for films.json")
    parser.add_argument("--window-look", help="opaque (the default: the launcher's own config), or KEY=VALUE[,KEY=VALUE...]: "
                                              "the keys of the window's look that the launch's config gets (window_look.py)")
    opts = parser.parse_args()
    try:
        opts.look = looks.window_look(opts.window_look)
        if opts.look and opts.look.get("behind", "desktop") != "desktop":
            raise ValueError(f"--window-look behind={opts.look['behind']}: this tool makes no panel behind the window")
    except ValueError as error:  # before the app starts: no film of another window than the one asked for
        print(f"pane-motion-films: NOT RUN: {error}", flush=True)
        return 3
    known = [spec["id"] for spec in FILMS]
    if opts.films == "list":
        print("\n".join(f"{spec['id']}\t{spec['title']}\t{', '.join(filter(None, (label(a) for a in spec['acts'])))}" for spec in FILMS))
        return 0
    wanted = [i for part in opts.films.split(",") for i in ([k for k in known if GROUPS[part](k)] if part in GROUPS else [part])]
    if not opts.app or [i for i in wanted if i not in known]:
        print(f"pane-motion-films: NOT RUN: needs --app and known film ids (not known: {[i for i in wanted if i not in known]})", flush=True)
        return 3
    # A film that opens a window goes last: a window that stays open is then in no other film.
    wanted = sorted(dict.fromkeys(wanted), key=lambda i: next(s for s in FILMS if s["id"] == i).get("crop") == "frame")
    opts.out = os.path.abspath(opts.out)  # the recorder writes the movie in the app's process
    opts.deadline = time.monotonic() + (opts.budget or 1e9)
    os.makedirs(opts.out, exist_ok=True)
    # No osascript in a step: the launcher leaves the sound as it is and its read of the mute state is a no-op.
    os.environ.update({"BENCH_LAUNCH_AUDIO": "keep", "BENCH_LAUNCH_OSASCRIPT": "/usr/bin/true"})
    needs_mock = [i for i in wanted if next(s for s in FILMS if s["id"] == i)["setup"] in MOCK_SETUPS]
    plan = [(False, [i for i in wanted if i not in needs_mock]), (True, needs_mock)] if opts.chat_mock == "auto" else [(opts.chat_mock == "1", wanted)]
    report = {"films": [], "failures": [], "launches": [], "limits": LIMITS, "key_repeat_ms": [opts.repeat_delay_ms, opts.repeat_ms], "mbps": opts.mbps,
              "alt_screen": "not read: no debug call says if a terminal is on its alternate screen", "build": build_facts(opts.build)}
    if opts.look:  # the look as the command line names it; each launch has what the app itself says it shows
        report["window_look"] = {"look": looks.look_tag(opts.look), **opts.look, "terminal_config": looks.look_terminal_lines(opts.look)}
    forms = list(LAUNCH_FORMS[opts.launch_form])
    try:
        report["host"] = f"macOS {platform.mac_ver()[0] or 'not read'}, {platform.machine()}, python {platform.python_version()}"
    except Exception as error:  # noqa: BLE001  a line for a reader of the log: its fault must not end the run before a film
        report["host"] = f"not read ({error!r})"
    print("PREFLIGHT host: " + report["host"], flush=True)
    for mock, idents in plan:
        if not idents:
            continue
        # A second launch makes the session again: it starts only with more time left than the first one's start took.
        spent = max((launch["start_s"] for launch in report["launches"]), default=0)
        reason = f"no time left in the step for a second launch (the first one's start took {spent:.0f} s)" if spent and opts.deadline - time.monotonic() < spent + 240 else ""
        reason = report.get("preflight_failed") or reason  # no launch form is left: no other launch, and each film has its row
        began = time.monotonic()
        try:
            while not reason:
                try:
                    launch_films(opts, mock, idents, report, began, forms[0])
                    break
                except (PreflightFailed, bench_launch.LaunchError) as error:
                    if len(forms) == 1 or isinstance(error, (SecondInstance, LookNotShown)):
                        raise
                    # This launch again, and each launch after it, in the next form.
                    print(f"PREFLIGHT next form: {forms[1]} (the {forms[0]} form failed: {getattr(error, 'reason', error)})", flush=True)
                    report.setdefault("forms_not_run", {})[forms.pop(0)] = str(getattr(error, "reason", error))
        except PreflightFailed as error:  # its PREFLIGHT lines are printed: no session, no film, no other launch
            reason = report["preflight_failed"] = f"the preflight failed (launch form {forms[0]}): {error}"
        except bench_launch.LaunchError as error:  # the launcher printed its BENCH-LAUNCH line
            reason = f"the app did not launch: {error.reason}"
        except Exception as error:  # noqa: BLE001  the rows so far still go into the report
            traceback.print_exc()
            reason = f"the tool stopped: {error!r}"
        if reason:
            report["failures"].append(f"page mock {'on' if mock else 'off'}: {reason}")
        done = {row["id"] for row in report["films"]}
        report["films"] += [{"id": named(report, i), "status": "not_run", "agent_page_mock": mock, "reason": reason[:800]}
                            for i in idents if named(report, i) not in done]
    report["launch_form"] = forms[0]
    for row in report["films"]:
        if opts.look:
            row.update(window_look=looks.look_tag(opts.look), **({"window_look_kind": report["window_look"]["kind"]} if "kind" in report["window_look"] else {}))
        # Why this film is not a film of that form, in the app's or the check's words; not on a film that is of that form.
        other = {form: why for form, why in report.get("forms_not_run", {}).items() if row.get("launch_form") != form}
        if other:
            row["forms_not_run"] = other
    with open(os.path.join(opts.out, "films.json"), "w") as f:
        json.dump(report, f, indent=1)
    # A speed that did not go back: the exit code does not say it, and a film after it can be at the wrong speed.
    for fault in dict.fromkeys(row["speed_fault"] for row in report["films"] if row.get("speed_fault")):
        after = [row["id"] for row in report["films"] if row.get("speed_fault") == fault and row["status"] == "made" and "speed" not in row]
        print(f"PANE-FILMS speed fault: {fault}; made after it with no speed call of its own: {', '.join(after) or 'none'}", flush=True)
    for row in report["films"]:
        if row["status"] == "not_made":
            print(f"PANE-FILMS not made: {row['id']}: {row.get('reason')}", flush=True)
        elif row["status"] == MOVIE_NOT_CHECKED:  # not counted below
            print(f"PANE-FILMS {MOVIE_NOT_CHECKED}: {row['id']}", flush=True)
    made = sum(1 for r in report["films"] if r["status"] == "made")
    print(f"PANE-FILMS made {made} of {len(wanted)} asked; failures {report['failures']}", flush=True)
    return 0 if made == len(wanted) else 2 if made else 1


def named(report, ident):
    """A film's id in this run: the id of FILMS, and for a window with a look the look's kind after it (`T-D-picture`).
    The kind is the app's own answer (window_look.py `look_kind`): no value of the option, no picture's name. An
    opaque window, and a look that no launch has shown yet, keep the id of FILMS."""
    kind = (report.get("window_look") or {}).get("kind")
    return ident + (f"-{kind}" if kind and kind != "opaque" else "")


def shown_look(app, look):
    """What the launched app says that its window shows, for the launch's facts. No film of a look from another
    window: the launch's own config files hold each named key, and the app's settings answer and its backdrop are
    the look, or LookNotShown ends the run with a `PREFLIGHT window look FAILED:` line."""
    tag, problem, seen = looks.look_tag(look), looks.look_problem(look, app.launched_env), None
    if not problem:
        seen, problem = looks.shown_look(app.rpc, look, monotonic=time.monotonic, sleep=time.sleep)
        # A film of a look has the look's kind in its name: no film under a name with no kind.
        problem = problem or (None if seen["kind"] else "the app's backdrop was not read: the look has no kind")
    if problem:
        print(f"PREFLIGHT window look FAILED: {tag}: {problem}", flush=True)
        raise LookNotShown(f"the window does not show the look {tag}: {problem}")
    said = seen["resolved"]
    print(f"PREFLIGHT window look: {tag}: the app shows {said['background']} {said['picture']!r}, opacity {said['opacity']}, "
          f"blur {said['blur']!r}", flush=True)
    return seen


def launch_films(opts, mock, idents, report, began, form):
    """One launch of the app in the key form `form`, with the agent pages' mock on or off: the preflight, the
    session, then the films of `idents`."""
    env = {"CMUX_NEXT_INPUT_JOURNAL": "1", **({} if mock else {"CMUX_NEXT_AGENT_PANE_MOCK": None}),
           **({"CMUX_NEXT_NO_ACTIVATE": None} if form == "activate" else {})}
    # A look: the launch's config holds the keys that the option names and no other (not the launcher's own config).
    app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, env=env, log_name=f"app-mock-{int(mock)}.log",
                                config=looks.look_config({}, opts.look) if opts.look else None)
    if looks.look_terminal_lines(opts.look):
        # The launch opens the terminal config file to append: the look's named lines stay in it.
        with open(os.path.join(app.scratch, "ghostty"), "w") as terminal_config:
            terminal_config.write("\n".join(looks.look_terminal_lines(opts.look)) + "\n")
    app.launch()
    facts = {"executable": os.path.basename(app.binary), "agent_page_mock": "CMUX_NEXT_AGENT_PANE_MOCK" in app.launched_env,
             "agent_launch": app.launched_env.get("ACPMUX_AGENT_LAUNCH"), "films": idents, "start_s": 0,
             "launch_form": form, "no_activate": app.launched_env.get("CMUX_NEXT_NO_ACTIVATE") == "1", "preflight": "not run"}
    report["launches"].append(facts)
    try:
        maker = Films(app, opts, mock, form)
        report["redraw_program"], report["stream_program"] = maker.program[0], "ping"
        try:
            facts["activate"] = activate(app, form)
            if form == "activate":
                facts["window"] = place(app)
            if opts.look:
                facts["window_look"] = shown_look(app, opts.look)
                report["window_look"]["kind"] = facts["window_look"]["kind"]  # from here each film's id has it (`named`)
            link, maker.zoom = preflight(app, maker.st, opts.out, opts.mbps, form, opts.display)
            facts["zoom"] = maker.zoom
        except PreflightFailed as error:
            facts["preflight"] = f"failed: {error}"
            raise
        except Exception as error:  # noqa: BLE001  a fault of a preflight call is a failed preflight too
            print(f"PREFLIGHT tool FAILED: {error!r}", flush=True)
            facts["preflight"] = f"failed: tool: {error!r}"
            raise PreflightFailed(f"tool: {error!r}") from error
        facts["preflight"] = "passed"
        facts["display"] = {k: link.get(k) for k in ("p50_ms", "refresh_ms", "frames")}
        if opts.workspaces:
            before = {w["id"] for w in maker.st.workspaces()}
            facts["session"] = seed(app, opts.workspaces, opts.live_shells, opts.page_url, opts.seed_deadline, opts.out)
            maker.session = [w["id"] for w in maker.st.workspaces() if w["id"] not in before]
            pins = [maker.st.action("palette.toggleWorkspacePin", {"pinned": True}, target=f"workspace:{w['id']}", focus=False)
                    for w in maker.st.workspaces()[:opts.pinned]]
            facts["session"].update(listed_by_the_app=len(maker.st.workspaces()), workspaces_of_the_maker=len(maker.session),
                                    pins_refused=sum(1 for r in pins if isinstance(r, dict) and r.get("error")), pins_asked=len(pins))
            print("PANE-FILMS-SESSION " + json.dumps(facts["session"]), flush=True)
        facts["start_s"] = round(time.monotonic() - began, 1)
        for at, ident in enumerate(idents):
            report["films"].append(maker.take({**next(s for s in FILMS if s["id"] == ident), "id": named(report, ident)}))
            if maker.stop:
                # A dialog or an overlay stays over the window: no other film of this launch.
                reason = f"the launch stopped after the film {named(report, ident)}: {maker.stop}"
                report["failures"].append(f"page mock {'on' if mock else 'off'}: {reason}")
                report["films"] += [{"id": named(report, i), "status": "not_run", "agent_page_mock": mock, "launch_form": form, "reason": reason[:800]} for i in idents[at + 1:]]
                break
    finally:
        facts["start_s"] = facts["start_s"] or round(time.monotonic() - began, 1)
        app.stop()


if __name__ == "__main__":
    sys.exit(main())
