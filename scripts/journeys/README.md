# User journeys

A journey is one thing a real person does with cmux, played against one exact build on a
fleet Mac, recorded as a clip, and judged by what the person would see. The journey suite is
the definition of done for a dogfood build ([holistic-quality](#why)): no dogfood build goes
to Lawrence until every P0 journey passes on that exact build, the earlier dogfood fixes are
all in it, and an independent QA agent says ship (`dogfood-gate.py`).

The lead runs journeys at the moments that matter (a dogfood build, a fix for a journey's bug,
before a handoff). They are not a CI job, step or gate, and must not become one.

## Run

```bash
# Every P0 journey against the app of fleet build job JOB (waits for the build if it still runs):
python3 scripts/journeys/run.py --build JOB

# One journey, a priority, or all of them:
python3 scripts/journeys/run.py --build JOB --journey ctrl-c
python3 scripts/journeys/run.py --build JOB --priority P1
python3 scripts/journeys/run.py --build JOB --all

# Against a commit: builds that exact pushed SHA on the fleet once (receipt in
# artifacts/journeys/builds/), then runs on its artifact:
python3 scripts/journeys/run.py --commit SHA

python3 scripts/journeys/run.py --list     # id, priority, file, title
python3 scripts/journeys/run.py --check    # validate the journey files (no fleet)
```

A journey that needs a display rate says `"require_hz": 120` (on the journey, a step, or a step inside a step group;
one rate per journey, a whole number of Hz in [24, 240]).
The minis' own displays run at 60 Hz, so it runs only on the lease's own virtual display:
`--whole-host --vdisplay 120x1` (1x pixels) or `--vdisplay 120x2` (2x, a Retina laptop's density). The lease
makes that display the main display before the app launches and measures it with a fresh process; a display
that is not the main one, or whose measured rate (within 0.35 ms of 1000/HZ) or pixel density is not the asked
one, makes the lease's journeys `not run`, and `display.json` (each lease's in `displays.jsonl`) keeps what was
measured. Without the right `--vdisplay`, such a journey is `not run` before any lease or build wait, with what
to pass.

Capture hosts come from the fleet registry (`~/.ssh/config.d/fleet-registry.json`, written by
leo-workspace `tools/reach --install`). On a machine without it, name them:
`--hosts "cmux17 cmux18 cmux19 cmux21 cmux22 cmux23 cmux24"` (sets `CAPTURE_HOST_SLOT_HOSTS`).
`JOURNEYS_EXCLUDE_HOSTS` (default `cmux16`) are never leased.

Output, in `artifacts/journeys/<job12>-<run id>/` (or `--out`, which must be a new folder):

- `results.jsonl`: one line per journey: `id`, `priority`, `status` (`pass`, `fail` or
  `not run`), `reason`, `evidence` (each check with its result, its time from the mark and
  what it saw), `clip`, `checks` (the frames the checks read), `build_job`, `commit`, `tag`,
  `host`, `path`, `nonce`, `run_at`, `run_id`, `run_started_at`, `harness`;
- `run.json`: the run id (`<UTC time>-<8 hex>`), its start time and the harness checkout;
- `<id>/result.json`: the full record (every step and its reply, every check's detail);
- `<id>/check-NN.png`: each frame a `frame_text` or `frame_marker` check read (full size);
- `<id>/clip.mp4` (with ffmpeg) or `<id>/clip.png` (an animated PNG, about a frame a second;
  any browser plays it) and `<id>/clip/`, the frames it is made of.

Exit 0 when every selected journey passed, 1 when one failed, 75 when none failed but one did
not run.

### One run, one folder; only its own results (STATUS 1362)

On 2026-10-31 an R3 round whose relaunch failed reported the `result.json` an older round had
left in its reused folder. So:

- Each run writes a new folder. An `--out` folder that holds an earlier run's files makes every
  journey `not run`; the earlier `results.jsonl`, `run.json` and `<id>/` folders are kept beside,
  named with this run's id (`results.jsonl.earlier-<this run id>`, `<id>.old-<time>-<pid>`).
- The driver writes the run id and run start into each `result.json`. `run.py` takes no
  `result.json` without both (`not run`, reason `stale or foreign result: ...`) and moves that
  folder aside as `<id>.foreign-<this run id>`.
- A lease whose launch (or a capture-host wrapper's relaunch) or set-up fails before the driver
  starts is `not run` with that reason; `run.py` reads no result then.

### Run fleet rounds from a pinned checkout

`run.py` loads the journey specs at its start and packs `driver.py`, `ext_*.py`, `smoke_hog.py`,
`build_names.py` and the text reader's source from disk at each lease. Run fleet rounds only from a pinned, reviewed checkout, never from the
worktree you edit in:

```bash
git worktree add --detach ../journeys-run REVIEWED_SHA   # move it only to a reviewed sha
cd ../journeys-run && python3 scripts/journeys/run.py --build JOB ...
```

`run.py` reads `git status` of `scripts/journeys`, `scripts/cmux-next/build_names.py` and
`scripts/ci/pr_media_ocr.swift` at the start and at each lease. A result from uncommitted
harness files, or from a checkout whose commit moved during the run, is `not run`
(`harness: unpinned (...)`), in `results.jsonl` and in `result.json`; the journey's own status
stays in the `harness` record (`commit`, `dirty`, `detached`, `pinned`, `status`), and a step
group's report (`fuzz.json`) is renamed `fuzz.json.unpinned`. That record names the harness commit of every result.

## How it runs (what it reuses)

No new harness: `run.py` takes the route `cmux-ci capture` (hq `build-fleet/pr-capture`) and
`scripts/cmux-next/restore-journey-slot.sh` already take.

1. The build: `cmux-ci status JOB` (its exact `ref` is the commit under test); a running build
   is waited on with `cmux-ci wait` (a wait timeout leaves it running: wait again, never
   resubmit).
2. `capture-host acquire --slot` leases one slot on a GUI capture mini (hq; the installed copy
   under `~/.local/share/cmux/hq-tools/current/build-fleet/` when `capture-host` is not on
   PATH). A lease lasts at most 10 minutes and is released in every case; journeys that do not
   fit one lease (`budget_seconds`) run in further leases.
3. The build comes from the mini's build cache (`~/.cache/cmux-journeys/builds/JOB/`); `build_cache.py`
   fills it once per mini and job, under a lock, so rounds that start at once make one download. It
   reads the store's signed URL with curl (a connection under 3 MB/s for 10 s is opened again) and
   checks the sha256, else `cmux-ci artifact JOB`. `run.py --prestage --build JOB --hosts "..."` fills
   it before any round, outside any lease, on each named mini that capture-host says is free. The slot
   compiles `scripts/ci/pr_media_ocr.swift` once per mini (`~/.cache/cmux-journeys/`).
4. `capture-host launch` starts the app in the slot: its own clone, bundle id, HOME, TMPDIR,
   control socket and empty settings file, never activated, never another app's state.
5. `driver.py` runs there (stock `/usr/bin/python3`, standard library) against the slot's
   socket. It warms text recognition up first (about a minute on a cold mini, recorded in
   `host.json`), then plays the journeys in one app, each in its own new workspace. `run.py`
   then fetches only the expected files and builds the clips.

The driver drives and reads the app only through interfaces the app already has:

| What | Interface |
| --- | --- |
| keys a person presses | `debug.key`: a key-down dispatched as `NSApplication.sendEvent` does (key router, key equivalents, menu, responder chain) |
| app state | the control socket: `debug.surfaces {text: true}` (each pane's focus, link, viewport text, `terminal_id`, `host_pid`), `action.run` |
| the daemon's screen | the bundled `cmux` CLI on the app's own daemon: `cmux terminal ID screen read` |
| processes | `ps`, scoped to the terminal's `__terminal-host` (`host_pid`), else to every process run from the app bundle |
| the frame | `debug.window_snapshot` (the app's own drawing of its main window) read with macOS text recognition (`scripts/ci/pr_media_ocr.swift`; an image in which it finds no text at all is read again in four horizontal bands) |

## Write a journey

One JSON file per journey under `journeys/<priority>/`. `run.py --check` validates it.

```json
{
  "id": "ctrl-c",
  "priority": "P0",
  "title": "Ctrl+C interrupts the foreground job; the prompt returns within 1 s",
  "why": "what breaks for the person, and the bug it guards (commit) if any",
  "source": "where it comes from: a dogfood bug, the action catalog, a shortcut, everyday use",
  "budget_seconds": 60,
  "steps": [ ... ]
}
```

`id`: lowercase, digits and dashes. `priority`: P0 (a person hits it in the first five
minutes: type, Ctrl+C, resize, scroll, paste, split, restart), P1, P2, P3. `budget_seconds`:
how long it may take (it plans the leases). Copy `journeys/p0/type.json` (the smallest) or
`journeys/p0/ctrl-c.json` (marks, timing, processes).

### Steps

| `do` | Fields | What it does |
| --- | --- | --- |
| `new_terminal` | `via`, `name` | `via: "key"`: the person's New Terminal Tab key (Ctrl-\`, newSurface) through `debug.key` (origin user: it claims the window's keyboard), then as `focused_terminal`; use it in every journey that plays what a person does. `via: "socket"` (the default, kept for older journeys): `action.run newTab` named `name` (focused); waits for the new focused terminal pane that holds the terminal the reply says it created (else the pane view's own creation key) and its first prompt; later steps use that terminal |
| `script_new_terminal` | `name`, `focus` | automation on purpose: a script's `action.run newTab` through the socket; adopts the terminal the reply says it created (`created`: the daemon's public id at once, or the creation's host id once its tab is the daemon's) and waits for its first prompt, without waiting for the workspace to show (a script's newTab does not take a text input the person has: cp/fix-chief-composer-focus); a reply that names no created terminal fails the step |
| `neutral_prompt` | | writes `PS1='J> '` (zsh and bash), `cd /tmp` and a clear into the PTY through the daemon (set-up, not under test; no host, user or path in any frame) |
| `type` | `text`, `enter`, `mark` | presses each character with `debug.key`, then Return when `enter` |
| `key` | `key`, `modifiers`, `mark` | one `debug.key` (`modifiers`: `control`, `shift`, `option`, `cmd`; named keys: `return`, `escape`, `tab`, `space`, `up`, `down`, `left`, `right`, `delete`, `pageup`, ...) |
| `rpc` | `method`, `params` | one control-socket request (set-up the person does through UI the driver cannot click yet) |
| `wait` | `seconds` | only when nothing observable can be waited on |
| `expect` | `all`, `since`, `within`, `timeout`, `settle`, `title` | polls every condition in `all` (about every 50 ms plus the reads) until all hold or `timeout` seconds pass; `settle`: the negative conditions must keep holding that many more seconds |
| `mouse` | `action`, `dx`, `dy`, `phase`, `modifiers`, `button`, `count`, `interval`, `mark` | `debug.mouse` at the center of the journey's pane, `count` times: `scroll` (default; `dy` > 0 is a wheel turned up, toward older rows), `click`, `double_click` |
| `select_text` | `text`, `how`, `occurrence`, `mark` | selects TEXT where the pane shows it, with the pointer: `drag` (default: press on its first cell, drag to its last) or `double_click` (a word); the cells come from the pane's viewport text and grid (`debug.surfaces`) |
| `clipboard_set` | `text` or `lines` (`format`, `count`, `start`) | set-up: puts the text on the Mac's general pasteboard (what Cmd+V reads; `pbcopy`) and reads it back; binds `${clip_sha}` (sha256) and `${clip_lines}` |
| `file` | `path`, `text` or `lines` | set-up: writes a helper program to `/tmp/jr-*` (only there; not substituted, so it takes the run's values as arguments); removed when the journey ends |
| `focused_terminal` | `timeout` | after a key that makes a terminal (Ctrl-\` New Terminal Tab, Cmd-D split, Home's Open a terminal): waits for a focused terminal pane showing a terminal not seen before, makes it current and waits for its first prompt |
| `use` | `name` | makes the terminal named `name` current again; its pane is read from the topology now (after a move or a relaunch) |
| `relaunch` | `how` (`quit`, `crash`, `kill-app`, `kill-both`, `quit-keep`, `quit-end-sessions`, `quit-end-everything`), `mark` | ends the app and opens it again as a person does: `quit` presses Cmd-Q (a quit sheet gets its default, as Return); `crash` is `debug.crash.app` (SIGSEGV in the app); `kill-app` is SIGKILL of the app, `kill-both` SIGKILL of its daemon and then of the app; `quit-*` run the File menu's quit of that kind (no dialog). Then `open -g -n -a` the same bundle with its launch variables (the slot's HOME, socket, settings file), waits for the new process and the loaded topology, and finds every named terminal again. `mark` is the moment the old process ended. `leftovers_after: S`: S seconds after the old process ended (before the reopen), lists every process of the bundle (its path, or `--owner BUNDLE_ID`) for `quit_leftovers` |
| `settings_file` | `set`, `unset`, `mark` | edits the app's own settings file (`CMUX_NEXT_CONFIG_FILE`, the slot's) as an editor does: `set` merges nested keys, `unset` removes dotted keys |
| `remember_value` | `source`, `name` | keeps `daemon_cols`, `daemon_rows` or `app_cell_height` of the current terminal as `${name}` |
| `fresh_app` | | the app must be the one capture-host launched from empty state with no journey before it (`not run` otherwise); the journey file says `"first_in_app": true`, so `run.py` starts a lease with it |
| `outwait_hold` | | the next key waits out the creation hold after the last key (below); use it after a tab switch onto a terminal whose view may come later |

Any step may say `"as": "NAME"`: the current terminal after it is named NAME, for `use` and for
conditions that take `name`. `key` also takes `repeat` and `gap` (seconds between presses).
`key`, `type` and `mouse` take `window`: a window a step named (`name_window`, `await_window`) or a
window id; the key is typed in (the click lands in) that window. Without it, keys go to the journey's
key window and `debug.mouse` to the first window.

A capture slot's window is never the key window (the app runs with `CMUX_NEXT_NO_ACTIVATE`).
Keys typed while the app holds them for a terminal still being made (`CreationInputCoordinator`:
after Cmd-D, Ctrl-\`, a restore; at most its 2 s `holdLimit`) are replayed through
`NSApp.sendEvent`, which only reaches the key window, so in a slot they are lost. A person's
window is key, so this is the slot's limit, not the app's. After `focused_terminal`, `relaunch`
and `outwait_hold`, the next `type` or `key` therefore waits until 2.5 s after the key that made
the terminal (checks do not wait). Typing ahead into a terminal still being made is not covered
by journeys in a slot.

`mark` names the moment of a step (for `type` with `enter`, the moment Return is pressed);
`expect`'s `since` measures from it. Strings may use `${nonce}` (six digits, new each run, so
no fixture or earlier run can show the expected text) and `${prompt}` (`J> `).

### Conditions (inside `expect.all`)

| Condition | Evidence | Holds when |
| --- | --- | --- |
| `{"daemon_line": "TEXT"}` | daemon | a line of the daemon's screen is TEXT (spaces at the ends ignored) |
| `{"daemon_contains": "TEXT"}` | daemon | the daemon's screen contains TEXT |
| `{"daemon_prompt": true}` | daemon | the screen's last non-empty line is the bare prompt |
| `{"app_text_line": "TEXT"}` | app | a line of the pane's viewport text in the app is TEXT |
| `{"app_text_contains": "TEXT"}` | app | the pane's viewport text contains TEXT |
| `{"app_prompt": true}` | app | the pane's last non-empty line is the bare prompt |
| `{"app_pane": {"field": value}}` | app | the pane's `debug.surfaces` fields equal these (`focused`, `link`, ...) |
| `{"process_present": {"match": "RE", "bind": "NAME", "foreground": true}}` | process | a process under the terminal matches RE (its full command line); `foreground`: it has a controlling tty and is in the tty's foreground group (`ps` stat `+`); `bind` keeps it as NAME |
| `{"process_gone": "NAME"}` | process | the bound process is gone (or a zombie) |
| `{"frame_marker": "TOKEN"}` | frame | a fresh snapshot of the window shows the marker of TOKEN, read from its pixels (`ext_marker.py`, below); use it for every line the journey itself writes |
| `{"frame_marker_lacks": {"token": T, "with": W}}` | frame | negative: a fresh snapshot shows W's marker, no marker of T and no unreadable marker |
| `{"frame_text": "TEXT"}` | frame | a fresh snapshot of the window shows TEXT to text recognition (spaces dropped, look-alike letters folded); only for app text a journey cannot mark |
| `{"daemon_lacks": "TEXT"}` | daemon | negative: the daemon's screen does not contain TEXT |
| `{"app_text_lacks": "TEXT"}` | app | negative: the pane's viewport text does not contain TEXT |
| `{"daemon_history": {...}}` | daemon | the daemon's scrollback (`terminal ID history read`): `rows` `oldest`/`newest`, `count`; `contains`, `lacks` (negative) TEXT; `pattern` (one group: a row number) with `contiguous` and `last` N |
| `{"app_rows": {...}}` | app | the numbered rows the viewport shows (after any scroll): `pattern`, `min_rows`, `contiguous`; `top`/`last`: `{eq\|ne\|gt\|lt\|ge\|le: N, a bound NAME, or "daemon_oldest"}`; `bind` NAME (sets `${NAME_top}`, `${NAME_mid}`); `hold` makes it negative-style (read every poll and through `settle`) |
| `{"frame_screen": {"shows": [...], "lacks": [...]}}` | frame | one fresh frame shows every `shows` text and none of `lacks` (a negative read only on a frame that shows the run's own text) |
| `{"clipboard": "TEXT"}` | clipboard | the general pasteboard is exactly TEXT (`pbpaste`) |
| `{"quit_leftovers": {"allow": [{"match": RE, "why": TEXT}]}}` | process | every process a `relaunch` with `leftovers_after` found after the quit matches an `allow` entry; the others are listed with their RSS |

A negative condition (`*_lacks`, `daemon_history` with `lacks`, `app_rows` with `hold`) is read again
every poll and holds only when it holds together with the positive ones at the end (and through
`settle`); a positive one holds once it has held. The capture minis share one pasteboard per login:
`clipboard_set` reads its text back before the paste, and the `clipboard` check runs within a second.

| `{"daemon_cwd": "PATH"}` or `{"daemon_cwd": {"name": N, "cwd": PATH}}` | daemon | the daemon's terminal list gives the terminal (current, or named N) that working directory (`/private/tmp` is `/tmp`) |
| `{"daemon_grid": {"cols_lt": V, "rows_equals": V}}` | daemon | the terminal's grid in the daemon (`cols`, `rows` with `equals`, `lt`, `gt`, `lte`, `gte`) |
| `{"daemon_pane_ready": {"tabs": N}}` | daemon | the current terminal's pane has at least N terminal tabs and each one's daemon screen shows text (a prompt) |
| `{"app_cwd": ...}` | app | the topology's tab of the terminal shows that working directory (same forms as `daemon_cwd`) |
| `{"app_layout": {"workspace": W, "windows": N, "panes": N, "tabs": N, "pane_tabs": N, "selected": true}}` | app | the current terminal's workspace in the topology has these counts; `selected`: its tab is its pane's selected tab; `bind_workspace: NAME` keeps the workspace's name as `${NAME}` |
| `{"app_tab_pane": {"same_as": N}}` / `{"not_same_as": N}` | app | the current terminal's tab is (is not) in the same pane as terminal N |
| `{"app_tab_gone": "N"}` | app | terminal N is in no tab of the topology |
| `{"app_rpc": {"method": M, "params": P, "path": "a.b.0", "equals"\|"contains"\|"len"\|"len_gte"\|"gt"\|...: V}}` | app | one control-socket read; the value at `path` meets every rule (also `not_equals`, `in`, `not_in`, `lacks`: a missing value fails them; `lacks` TEXT: the value, as JSON text unless a string, does not contain TEXT); `bind: NAME` keeps the value as `${NAME}` |
| `{"app_grid": {"cell_height_gt": V}}` | app | the pane's drawn grid (`cell_height`, `cell_width` with `equals`, `lt`, `gt`, ...) |

`within` (seconds) makes a timing claim: each condition must first hold within that long of
`since`, or it fails with the measured time. Frame checks are read after the other conditions
hold (text recognition takes about a second) and do not count against `within`.

### The journey's own lines: frame markers, not text recognition

A frame check of a line the journey writes (`${nonce}-42`) is a marker, not `frame_text`: on 2026-11-03 the text
reader read "733287-42" as "733287-4źął", "jq-447486-400" as "j9-447486-400", and returned no line at all for a
correct frame (STATUS 9303, 9402, 9444). `ext_marker.py` makes the terminal draw the token as one row of 30
truecolor cells under its text line, and reads it back from the snapshot's pixels with a check (no language model;
`test_ext_marker.py` decodes 800 markers in 200 frames, through the color changes a capture can make, and refuses all
3000 corrupted ones).

```json
{"do": "marker_install"},
{"do": "type", "text": "${marker} ok-${nonce}-$((6*7))", "enter": true, "mark": "typed"},
{"do": "expect", "since": "typed", "all": [
  {"daemon_line": "ok-${nonce}-42"}, {"app_text_line": "ok-${nonce}-42"}, {"frame_marker": "ok-${nonce}-42"}]}
```

`marker_install` writes the program to `/tmp/jr-m-<nonce>` and binds `${marker}`; the program prints the token as a
text line (the daemon and app checks see what `echo` printed), a blank line, the marker and a blank line (no glyph of
a text line can reach a marker pixel row). It needs the pane's own width to be at least 30 columns (it reads the
terminal's size, not an exported `COLUMNS`; it exits 3 when the pane is narrower and 4 when its output is no
terminal), and the typed command line itself is about 40 columns. `frame_marker_lacks {"token": T, "with": W}` is the
negative for the journey's own lines (the frame negative for other text stays `frame_screen` `lacks`): it holds only
on a frame that shows W's marker and has no unreadable marker, and it fails at once on the first frame that shows T's
marker together with W's, also beside an unreadable marker (a later frame without T does not undo it). A frame without
W is tried again, as it may be from before the step's output, and so is a frame with W and an unreadable marker but no
T marker. Like every frame condition it is read on fresh snapshots
after the step's live conditions hold and after its `settle` time, and it stops at the first frame that holds: a T
marker that shows only before that frame, or only after it, is not seen. It proves the absence only where the frame shows the
pane, so a marker scrolled away or covered is not seen either way; nor is a marker drawn under 6 pixel rows or one
whose START cells are covered (neither is reported, so they do not make the negative fail; a covered data cell does, as
an unreadable marker). A marker whose cell edges are blended (a scaled thumbnail) reads as its own token, as an
unreadable marker or not at all, by how far it is blended and how the capture changes its colors (measured with one
pixel column per edge: up to 0.37 of the neighbour's color with no color change, from 0.07 to 0.37 after the P3 and
dimming changes the tests use). It never reads as another token, and the negative cannot rely on seeing it. A marker
reads where the window shows it, not only
in the journey's pane: a thumbnail of a pane with cells of 4 px or more would read too. A check's detail lists the first
20 markers it found (position, cell width, line height and 24-bit digest, the first six hex digits of sha256 of the
token).

What a marker proves and what it does not: that this run's terminal output reached the window's pixels, at the cell
grid, in colors a capture keeps. It draws cell backgrounds only, so it does not prove that glyphs render: a build that
draws no text would still show markers. Journeys that check the app's own text keep `frame_text` (with its fold of
look-alike letters, `OCR_FOLD`; the P0 journey runner reports a `frame_text` miss whose daemon and app checks of the
same text passed as "not judged: reader misread"). Real-app rounds (2026-11-03), 0 unreadable markers in 1155 reads (both journeys of each round):
1x on cmux21 and 2x on cmux23 (16 x 34 px cells, the lease's own 120 Hz display) with the first layout (no blank
lines), and 1x on cmux21 with this layout (8 x 17 px cells). A frame check at 2x took about 1.5-1.8 s on a mini (the
standard-library reader of a 2200x1440 snapshot).

### Step groups (`ext_*.py`)

A group's own steps and conditions live in `ext_<group>.py` beside `driver.py`; the driver loads
each one (`load_extensions`) and `run.py` sends them to the mini with it. A group file has
`install(driver)`, `STEPS` and `CONDITIONS` (name to evidence kind and function), must not import
`driver.py`, and may not redefine a step or condition. A journey may have `finally` steps (put the
app back for the next journey: leave full screen, close a second window, restore the window
frame); they run whatever happened and never change the status.

A group may list its negative conditions in `NEGATIVE` (a live one is read every poll and through `settle`, as
`*_lacks` are; a frame one fails at once on a frame whose detail says `seen`, what it forbids, and is not tried
again).

`ext_multiwindow.py` (group multi-window, `journeys/p0/mw-*.json`) judges which window an input acted
in: the target window changed as asked and every other window did not change. Steps: `name_window`,
`await_window` (the window Cmd-Shift-N, the menu, the CLI or a move just opened), `use_window`,
`remember_windows`, `click_sidebar` (the Home item or a workspace row, clicked with `debug.mouse` at
its `debug.sidebar_rows` frame), `move_workspace` (Move Workspace to Window, an explicit window),
`run_cli` (the bundled `cmux` on the app socket) and the clean-up `close_extra_windows`. Conditions:
`window_state` (what one window shows: Home, a workspace by name, its rows, its first sidebar entry,
pane and tab changes since a mark), `window_unchanged` (negative: every other window still shows the
same page, workspace, rows, panes, tabs, focused pane and frame), `windows_open`, `windows_show`.
The file's docstring has every field.

`ext_spam.py` (group shortcut-spam, `journeys/p0/spam-*.json`) holds a shortcut down and hammers it (handoff
input-principles.md, hold-shortcuts-ux.md, repeat-runoff.md). Keys go out on the system's schedule, one thread
each, stamped with their scheduled time, so a main thread that falls behind sees a queue of old repeats as with a
real held key; `debug.key {repeat: true}` sends an auto-repeat (the app's repeat gate reads that key as down).
Steps: `spam_remember`, `hold_key` (one press, repeats every 33 ms from 250 ms, then the key is up; keeps the counts
one frame after the key-up as `AS_release`), `hammer_key` (N physical presses within T seconds). Conditions:
`spam_counts` (tabs, panes, the focused pane's tabs, workspaces against a remembered count, by a delta or by the
runs a hold reported), `spam_unchanged` (negative: nothing changed after the key-up, with `settle`),
`spam_selected` (the selection moved N places, for Ctrl-Tab and Cmd-Shift-[ ]), `spam_runs`. The docstring has
every field. The 10x slow-motion clips need the Motion Inspector (cp/motion-inspector-N) in the build.

`ext_window.py` (group window-pane-resize) adds pointer and window steps. Drags go through
`debug.mouse`: a press, one drag event per 60 Hz frame with the button held, a release, so
AppKit's live-resize tracking or the layout's divider drag reads them as it reads a person's drag.
Steps: `name_pane`, `adopt_pane` (the pane a split or a new window just focused), `use_pane`
(`click: true` clicks into it first), `remember`, `window_place` (set-up), `window_drag`
(`press: false` / `release: false` keep the button held, so checks run inside the live resize),
`divider_drag`, `action`, and the clean-ups `leave_full_screen`, `restore_window`, `close_window`.
Conditions: `window_frame`, `full_screen`, `grid_fits` (the pane shows; the app's grid equals its
fitted grid, Ghostty's drawn grid and the daemon screen's size, and fits the view's frame at
Ghostty's cell size), `pane_frame`, `pane_state`, `at_bottom` (the app's viewport ends with the
daemon screen's last lines: the scrollback did not jump), `output_advances`, and `pty_size`
(daemon evidence: the shell's `echo TAG $(stty size)` equals the daemon screen's and the app's
grid). The file's docstring has every field.

## Judge

The driver decides, not the author:

- `pass`: every step ran, every condition held (in time), and the passing checks include app
  state, the daemon's screen and a frame. A journey whose file lacks any of the three does not
  validate. "Pixels changed" is never a check: a frame passes only when text recognition reads
  the run's own expected text in it, so a blank frame, a fixture or an earlier run cannot pass.
- `fail`: a step failed (the error says which and why) or a condition did not hold.
- `not run`: the journey could not be played (no capture slot, the build failed or still
  builds, the app never answered, the lease ran out). Never counted as a pass.

Check the clip anyway: a pass says the checked text showed; the clip shows what else did.

## Film judges and judge goldens

The film judges read the in-app recorder's films (`debug.motion` `record_*` and `trace_*`): `video_judge.py`
(pacing, exact-scanline geometry, model against shown, content, recorder faults), `video-cases/judge_trace.py`
(per-frame geometry of a layout motion, one motion per drag), `video-cases/judge_keys.py` (each keyboard resize
press) and `video-cases/judge_scan.py` (repeated pictures in motion). They run on the VM with the venv
(`/work/tmp/bv-venv/bin/python -I`, numpy and imageio_ffmpeg), never on a mini. This folder holds the one copy;
the kit branches' copies are older (REWRITE R-HARNESS, handoff/rewrites/R-HARNESS/DESIGN.md).

Every change to a judge reproduces the judge goldens. They have two tiers:

- BASELINE: every gallery film, frozen read-only in `/work/goldens/judge-films` (sha256-pinned by
  `judge-goldens/films.json`), with the judges' results on it (`judge-goldens/expected.json`, one line per film).
  A change here is a difference to explain, then bless.
- TRUTH: answers known without the judges (`judge-goldens/truth.json`). A ruler fact is read by a judge-free pixel
  ruler from the stored film's exact scan lines (a run of one fixture color on one scan line in exactly these
  frames, and not in the 6 frames either side); an expectation says what a judge must or must not report on that
  film. The judges' own unit tests (`test_video_judge*.py`, `video-cases/test_judge_*.py`) are TRUTH too. A TRUTH
  failure fails `run` and refuses `bless`: it cannot be blessed away. Add a fact only with its evidence (who proved
  it, how) in its `why`. A fact that cannot be checked is NO VERDICT in both: its film is not in `films.json`, it has
  no `why`, an unknown key, no ruler and no expectation, an expectation of an unknown form or of a kind its judge
  does not report (`check`, `defect_frames` and `absent_check` are video_judge's findings; `kind` and `absent_kind`
  are judge_trace's defects), a judge that does not judge its film, or an empty or reversed span; so is a check, kind
  or absence of a name its judge does not report or that is no text, a missing `truth.json`, and a skipped judge unit
  test (the runner gives the tests the store it judges as `JUDGE_GOLDENS_STORE`). A name is read at the severity its
  judge writes it with (`NAMES` in `judge_goldens.py`, pinned to the source: 14 video_judge names are defects, 5 notes
  and 4 recorder findings). An absence fails when the judge reports the name; when it does not, it holds only where
  that name's own check looked, as the result shows it (`NEEDS`: complete frames, a motion window, trace samples, a
  tracked divider, a divider compared with the trace, the film's movie in the store, a HID drag in the film's pinned
  `events.json` that the judge placed (for `jump back`); for judge_trace a judged motion, an edge that travelled for
  `reverse`, `lurch` and `end-jump`, and 2 or more panes at rest for `gap`, `overlap` and `overlap-fading`); else it is
  NO VERDICT. Five video_judge names need an input that its result does not show: the two input-started checks
  (`main thread missed refreshes before the first frame`, `frame gap during slow input`) and the three step checks
  (`jump`, `jump back`, `jump back (animation)`: check_steps judges only dividers that moved more than 2 px): a fact
  of an absence of them is refused before any film is judged, until the judge writes that count. A check (must report) needs no coverage: a judge that did
  not look, and so missed it, fails. A ruler fact also needs the film's
  scan records to be its complete frames, one each, in order (the judge's frame numbers).

```bash
PY=/work/tmp/bv-venv/bin/python
agent-sandbox $PY -I scripts/journeys/judge_goldens.py run                    # all reproduced, TRUTH holds: exit 0
agent-sandbox $PY -I scripts/journeys/judge_goldens.py run --only 'feat-5851715-120x2/*'
agent-sandbox $PY -I scripts/journeys/judge_goldens.py bless --reason "TEXT"  # after a reviewed judge change
agent-sandbox $PY -I scripts/journeys/judge_goldens.py snapshot --source /Users/lawrence/fun/wt/handoff/resize-videos
$PY -I scripts/journeys/test_judge_goldens.py          # the runner's own tests (also _truth.py and _review.py)
```

- Exit 0: every result reproduced and every TRUTH fact and unit test holds. Exit 1: a judge's result changed, a
  TRUTH expectation failed or a unit test failed; each film and judge is printed with the summary that moved and the first JSON paths.
  Exit 2 (NO VERDICT, never a pass): the run cannot say. A film's judges over `--film-seconds` (default 300 s; the
  slowest of the 834 films takes about 50 s, and each run prints its slowest film; the budget holds also for a
  film process that closed its output), the run over `--deadline-minutes`, a judge process that dies, `judge_scan`
  timed out, ended by a signal or hit by an error of the machine, out of memory, an operating-system error of the
  machine, a result with no stable JSON form, a pinned store file that changed or is missing, a blessed result that is
  gone or changed, a judge or runner file that changed during the run, another toolchain (python, numpy, the ffmpeg
  binary), a TRUTH fact that cannot be checked or a
  ruler fact the film does not show, an expectation whose check did not look, a unit-test file that is ended by a
  signal or reports no count, a skipped unit test, or no film selected.
- Each film is judged in its own process (its process group is ended at the budget), in a sealed view that holds
  only its folder's pinned files (reflinks under `<store>/.scratch`), with bytecode that only this run wrote (a prefix
  per run): a result cannot depend on `--jobs`, film order, an older run's bytecode, or a file the table does not
  pin. The runner starts and signals processes: run it under
  `agent-sandbox`.
- A judge PR runs `run` on its head, names the changed films and why each change is right, then `bless` with that
  reason in the same PR. A bless needs the judge files and `judge_goldens.py` committed and records both (the
  runner makes the judges' inputs and normalizes their results). A change on no film needs a film that shows it: a
  new gallery film (`snapshot`, `bless`) or a TRUTH fact.
- `snapshot` takes a gallery folder only when no file in it changed for 10 minutes (`--settled-minutes`), decides
  the whole folder before it copies a file, never replaces a stored file (whatever its manifest records: a file the
  store holds with the same bytes is recorded with no copy, other bytes refuse the folder), and refuses a new input of
  a recorded film or folder (`display.json`, `diag-tiers.json`, `<film>.*`): a changed film needs a new folder name.
  It copies with reflink, so it needs no space.
- One store serves every manifest: a branch that adds films (S1b, a judge PR's new film) snapshots them into the same
  store before it lands. `run` and `bless` check only the files their own table pins, and count the others in a note
  ("the store also holds N folder(s) and M file(s) this manifest does not pin"). No unpinned file decides a result:
  each judge reads only its folder's pinned files (sealed views), the TRUTH ruler reads only a pinned scan and
  frames.json, and the drag need only a pinned events.json; `snapshot` plans each folder against everything the store
  holds, whatever manifest stored it, so it never adds an input to a stored film. One snapshot runs at a time: it holds
  a lock on the store (`<store>/.snapshot.lock`) and waits up to `--lock-seconds` (600) for it. A snapshot plans a
  folder against the files some files table in `<store>/tables` pins, so the files of a snapshot killed in its copy
  are taken again as the same bytes or refused; a file is linked into place, never replaced. A new film whose name has
  a dot, or is a folder file's name (`display`, `diag-tiers`), is refused. The judges' unit tests read the store by name
  (`JUDGE_GOLDENS_STORE`): a test reads only the pinned files of the film it names.

## Gate a dogfood build

```bash
python3 scripts/journeys/dogfood-gate.py --build JOB
```

It refuses (exit 1) and prints the build report unless:

1. every commit in `dogfood-fixes.list` is an ancestor of the build's commit (add each dogfood
   fix there in the commit that lands it);
2. every P0 journey's newest result for JOB (any `results.jsonl` under `artifacts/journeys`,
   `--results`) is `pass` on the build's commit, with passing app, daemon and frame evidence and
   its check frames on disk;
3. the independent QA verdict file `artifacts/journeys/qa/<JOB>.json` (`--qa`) says ship.

The QA agent is not the author: it gets the build (tag and job) and `run.py --list`, never the
diff; it uses the build as a new user and tries to break it, files each failure as a new
journey and a bug, and writes:

```json
{
  "build_job": "JOB",
  "commit": "FULL SHA",
  "verdict": "ship",
  "qa_agent": "who ran QA",
  "author_agent": "who wrote the build",
  "tried": ["typed in a new terminal", "Ctrl+C on sleep and cat", "..."],
  "failures": [{"what": "...", "journey": "journeys/p0/NEW.json", "bug": "issue or bead id"}]
}
```

Any other verdict, an empty `tried`, a failure without a filed journey and bug, or a QA agent
that is the author refuses the build.

## Dogfood smoke gate (10 of 10 under memory pressure)

```bash
python3 scripts/journeys/smoke-gate.py --build JOB [--rounds 10] [--swap-gb 15]
```

cmux-ad 2026-10-30 (stop the line, item 2): a build goes to Lawrence only with
`/Users/lawrence/fun/wt/handoff/dogfood-smoke/<JOB>.pass`, which only this gate writes, and only
when `journeys/dogfood/smoke-dogfood.json` passed every round (10 of 10). Each round is one run of
`run.py --journey smoke-dogfood --exclusive --hog-swap-gb 15`:

- `--exclusive`: the lease owns the whole mini (`capture-host acquire --slot --exclusive`), so no
  fleet step runs there during the round (the fleet rule for evidence).
  The perf minis are owner-only for pool `perf-lead`, so the gate sets `CAPTURE_HOST_POOL=perf-lead`
  (capture-host passes it as `--owner-pool`; hq #5153: an older hq-tools install gets HTTP 409).
- `--hog-swap-gb`: the Austin's-day memory hog (`smoke_hog.py`, a copy of feat's
  `scripts/cmux-next/austins-day/hog.py` until perf has it) holds incompressible memory until swap
  used is that much above the start, gives memory back near the edge, and ends by its own
  deadline; run.py starts it before the download and launch (at least 45 s before the journey)
  and stops it by its pid. A 16 GB mini may reach its free-memory edge before +15 GB of swap; the
  gate counts a round only when its hog log shows pressure (at least 4 GB held and swap +15 GB or
  `kern.memorystatus_level` down to 20), and reports what each round reached.

The journey (group `ext_smoke.py`): Cmd-N then Ctrl-\` three times (three workspaces, each with a
terminal: a person's Cmd-N shows the New Tab page; Ctrl-\` comes as soon as the workspace shows,
as a person presses it, before the daemon may have confirmed it), a line typed into each new terminal at once;
Cmd-D twice fast, a line typed into each new pane at once; Ctrl-\` twice fast, a line typed into
each new tab at once; Cmd-Shift-L, example.com, Return; Cmd-Q and reopen, the same three
workspaces (ids, as recorded once the daemon confirmed them) with their output back; close all. Each step is checked by the app's state
(topology, `debug.surfaces`, `debug.focus`, `debug.windows`, `debug.window_list`, `debug.crashes`),
the daemon's screens and a window frame (`check-NN.png`). `smoke_new_terminals` proves the keys
went to the new terminals: each line is on exactly one terminal, that terminal is new, it is where
it should be (its own new workspace, its own new pane, or a new tab of the focused pane, which
gained exactly that many tabs), and the last line is on the focused terminal. `smoke_panes` counts the panes of
the workspace whose terminal shows a line (the driver's `app_layout` needs a terminal it adopted itself).

**Resize (R3a) and new columns (R3b)** (cmux-ad orders 3 and 4, 2026-10-31; Lawrence: "resizing
terminals is broken", "creating new columns must never resize existing columns"). After Cmd-D twice,
the journey drags the divider between the two new panes and then the window's right edge. After each,
in the shown terminal: grid == fitted grid == drawn grid == fit(the view's bounds at the cell size) ==
the PTY's size (`stty size`) == the daemon's screen size == the topology tab's size, and a line longer
than the old width wraps at the new width (`smoke_r3`; every size is in the result; the window check
also needs the window 160 points narrower and the pane narrower than before). Both are re-read through
a 1.5 s settle. Then New Column twice (the action, then its key Ctrl-Cmd-X): every existing column
(matched by its panes, width from the float view frames) keeps exactly its width, and there is one
more column each time (`smoke_same_widths`; each old and new width in the result). Cmd-D (Split
Right) is not used here: it never opens a column (`SplitRoomCheck.toolSplit`), it splits the pane.

**Typed at once** (`smoke_type_now`): no wait for the creation hold, the case Lawrence reports
(keys into a terminal while it is created). A capture slot's window is never key
(`CMUX_NEXT_NO_ACTIVATE`), and held keys are replayed through `NSApplication.sendEvent`, which
reaches only the key window. So the journey first makes its window key without activating the
app (`smoke_make_key`: `debug.window.focus`, which calls `makeKey()` and reports the key window),
and each check and each type-at-once step reads that a main window is still key
(`smoke_key_window`, `debug.window_list`; not key before typing: known gap).
If the window did not become key, the round is "not run: known gap", which never passes the gate.
`smoke-gate.py --whole-host HOST` takes that mini whole (exclusive) and launches the app active
(`capture-host launch --activate`; the driver's relaunch then opens it in front too), so its window
is key and every line is typed at once. It needs CuaDriver's grants, given at the mini's console.

Verdict: PASS (every round passed, 10 rounds or more at +15 GB; the `.pass` file holds the
summary, the rounds' leases, pressure and results, and the gate's commit; a gate with uncommitted
changes never writes it), TRIAL PASS (all passed with fewer rounds or less swap: no `.pass`), FAIL
(a round failed: the summary names its step), NOT JUDGED (no failure, but a round did not run or
showed no memory pressure), DIAGNOSTIC (`--diagnostic`: where the slot has no key window the lines are
typed after the creation hold, every other check runs and is counted per round; never a `.pass`). A round counts only with its own fresh results for this build; `--out`
must be a new folder. Writes `summary.json` and `summary.txt`. Test:
`python3 scripts/journeys/test_smoke_gate.py`.

## Action fuzz (correctness and speed, one harness with the smoke gate)

```bash
python3 scripts/journeys/fuzz.py --build JOB --base BASE_JOB [--minutes 10] [--set layout|full] [--corpus] [--diagnostic]
python3 scripts/journeys/fuzz.py --build JOB --replay artifacts/fuzz/<run>/repros/found-<oracle>-<seed>.json
python3 scripts/journeys/fuzz.py --plan --seed 7 --set layout          # a seed's plan, no fleet
python3 scripts/journeys/test_fuzz.py; python3 scripts/journeys/test_fuzz_sim.py   # no fleet, no app
```

cmux-ad 2026-10-31 (Lawrence: "we need to fuzz greater for both correctness and speed"). The fuzz is a mode of this
driver: `ext_fuzz.py` adds the step `fuzz_run` (journey `journeys/fuzz/action-fuzz.json`), and `fuzz.py` runs it in
rounds through `run.py` (`--exclusive` leases in pool perf-lead, never cmux17 or cmux16). It plays a seeded plan of user
actions through `debug.key` (the key router's real path, as the gate's keys), ext_window's drags and the driver's
relaunch, at mixed timings (`now`, `pair` within 60 ms, `slow` 1.5 s), and keeps a model of the expected workspaces,
tabs, terminals and panes. After every burst it runs the oracles, which reuse the gate's own conditions:

| Oracle | Holds when |
| --- | --- |
| `create` | a create reached the model's prediction, or the app showed a refusal (`debug.toast` refusals); a probe line typed into the new terminal runs there and nowhere else |
| `r3a` | every shown terminal passes ext_smoke's `smoke_r3` (grid == fit == drawn == fit(bounds) == daemon == topology, and == the PTY where a probe printed `stty size`) |
| `r3b` | after a burst that only adds columns (New Column, Cmd-D), every old column keeps its exact width (ext_smoke's `smoke_same_widths` reading) |
| `focus` | `debug.focus` has no model/first-responder mismatch (weak in a slot: no key window) |
| `topology` | every terminal the app shows is in the daemon's list; `debug.desync` has no violation |
| `stall` | no `debug.hangs` record over 100 ms with a cmux frame |
| `crash` | the app lives, its daemon is connected, a quit's relaunch is clean |
| `leak` | after close-all, PTYs and non-helper processes at the first close-all's count; fds and browser helpers within a margin |

Leases (cmux-ad 09:05Z, binding): a capture lease is held only while journey steps run. Each round is one lease
(acquire right before the round, release right after it, on every path: run.py turns SIGTERM into an exception so its
`finally` releases, an acquire stopped by a signal is ended so capture-host unreserves, and fuzz.py passes its own
SIGTERM to run.py as TERM, never KILL; `test_run_release.py`). The build comes from a per-mini cache outside the slot
(`~/.cache/cmux-journeys/builds/<job>/`, the newest 3 jobs), so only the first round of a job on a mini downloads it,
under the mini's lock for that job (`~/.cache/cmux-journeys/locks/<job>.lock`; `test_build_cache.py`), and
`run.py --prestage` can fill it before the first round.
Nothing is shrunk inside a lease: fuzz.py runs ddmin with one short replay lease per try (`--shrink-tries`, default 10).

Sets: `layout` (fuzz-catalog row m, the first mode: New Column, Cmd-D, Split Down, Ctrl-`, close pane, divider drag,
window resize, relaunch) and `full` (also Cmd-T, Cmd-N, closes, workspace switches, typing, paste, a browser URL,
close all). A failure is shrunk by fuzz.py (ddmin, each try a fresh app in its own short lease; the layout set starts every run
with all workspaces closed and one fresh Ctrl-` workspace), confirmed, and written as a regression journey (`OUT/repros/found-<oracle>-<seed>.json`, red on that build). The
corpus `journeys/fuzz/lawrence-*.json` (`--corpus`) plays Lawrence's reported bugs as fixed sequences.

Speed: each create records `shown_ms` (key to the new terminal's pane drawn, not blank) and `typeable_ms` (key to its
prompt in the drawn viewport; Cmd-T: the New Tab field focused). No build has a present (photon) timestamp yet, so
these are the app's drawn state, read the same way on both builds. `--base` plays the same seeds on the base build on
the same mini, ABBA over rounds; a mark is red when the build's p50 is 25 % and 40 ms over the base's and its p90 is
worse, with at least 4 samples each.

Verdict: CLEAN (writes `handoff/dogfood-fuzz/<JOB>.clean`), RED, NOT JUDGED, or DIAGNOSTIC (`--diagnostic`: a slot
has no key window, so every key after a create waits out the 2.5 s creation hold; typing at once, quick pairs of
creates and the focus oracle are weak there; never a clean file).

## TUI load kit (layout-animation videos)

`tui-kit/` holds the seeded terminal load for the real-app videos of layout animations (RESIZE VIDEOS,
STATUS 4263): demanding programs for 4 to 12 panes, a browser page and an agent stand-in. Standard
library only, Python 3.9 (the minis' `/usr/bin/python3`; they have vim 9.1 but no htop or btop, so the
kit has its own `top`). Every program takes `--seed N` (the same seed draws the same frames),
`--duration S` (0: until a signal) and `--log FILE` (JSON lines stamped `wall` = `time.time()` and
`mono` = `time.monotonic()`), and ends cleanly on its deadline, SIGINT, SIGTERM or SIGHUP.

```bash
K=scripts/journeys/tui-kit/tuikit.py
python3 $K gradient --seed 7 --duration 60 --log /tmp/g.jsonl   # 120 fps truecolor gradient, box art, CJK and emoji
python3 $K gradient --pace sleep ...                            # pacing: spin (gradient default, one core), hybrid, sleep
python3 $K build-bins                                           # once per Mac: tk-gradient, tk-storm, tk-beacon (cargo, std only)
python3 $K beacon --ws N --pane M [--hz 240] [--fill]            # SWITCH FRAMES beacon (compiled; rt pacing; CLOCK_UPTIME_RAW)
python3 scripts/journeys/tui-kit/pace_probe.py --seconds 30      # frame intervals per pacing variant on this host
python3 $K describe --seed 7 --size 120x40                        # where gradient puts each element (columns, rows)
python3 $K sigwinch --seed 7 --duration 60 --log /tmp/w.jsonl   # one reflow per new size; every SIGWINCH logged
python3 $K mouse --seed 7 --duration 60 --log /tmp/m.jsonl      # curses, SGR 1006 mouse, cursor at (rows//2, cols//2)
python3 $K flood --seed 7 --duration 60 [--rate N] [--width 48] # numbered lines with a CRC, as fast as `yes`
python3 $K verify < screen.txt                                  # torn, lost or stale flood lines in a screen read
python3 $K vim-scroll --seed 7 --duration 60 --log /tmp/v.jsonl # vim scrolls a generated 100k-line C file
python3 $K top --seed 7 --duration 60                            # htop look-alike at 30 fps
python3 $K agent-stream --seed 7 --duration 60 --cps 400         # an agent's streamed answer in a terminal
python3 $K html --seed 7 --out /tmp/anim-7.html                  # the browser pane's page (or: serve --seed 7)
python3 $K scenario --panes 12 --seed 7 --write                  # which program runs in which pane: manifest.json
python3 scripts/journeys/tui-kit/heavy_profile.py build --tag TAG --seed 7 --out /tmp/tk-heavy-7
python3 scripts/journeys/tui-kit/heavy_profile.py teardown --manifest /tmp/tk-heavy-7/heavy.json
python3 scripts/journeys/tui-kit/test_tuikit.py                  # the kit's own tests (no app, no fleet)
```

What the analyzer reads in a frame:

- `gradient`: the compiled `tk-gradient` draws it when built (`tuikit.py build-bins`; `--engine rust|python`), byte for byte the
  Python engine's frames; a run below 95 % of its target fps logs `verdict: NOT RUN` in its `end` event. It spins to each frame's due time by default (`--pace spin`, one core): on a fleet mini a
  sleeping 120 fps loop woke in bursts (frame interval p95 47 ms, pace_probe job 0a364ec0ef40). Top-left `F<frame> t=<s> seed=<n> <cols>x<rows>`; on row 2 a barcode: a magenta guard
  cell, 20 cells of the frame index (white 1, black 0, most significant first), a cyan guard; a 3x5
  block-digit counter bottom right (panes of 50x18 or more). The frame log gives each frame's write
  time, so a video frame maps to a program frame. Frames are inside synchronized-update brackets
  (`--no-sync` drops them), so a torn frame is the terminal's, not the program's.
- `sigwinch`: header `SIGWINCH <cols>x<rows> winch=N reflow=M`; a new tint, the cards and the red right
  edge and bottom-row line move only at a reflow. The log has one `sigwinch` line per signal and one
  `reflow` line per new size: one reflow at the end of a resize is the rule.
- `mouse`: the cursor rests between `[` and `]` at (rows//2, cols//2); rows 3-5 from column 4 are an
  inverted block; a press draws its number where it lands and is logged (`press`, 1-based x, y).
- `flood`: `<10-digit line> s<seed> <payload> #<crc32>`; keep `--width` under the pane's columns.
- The page: a CSS slide, spin, pulse and hue animation; `F <n>` and 16 boxes count rAF frames;
  `window.tuikit.longFrames` counts frames longer than 1.5x the median.
- The agent pane: `agent_stream_acp.py` is acpmux's `fake_agent.py` with the prompt
  `stream: SEED SECONDS CPS` (numbered paragraphs `[pNNNN]`, tool calls, diffs).

`heavy_profile.py build` makes, on a running tagged build, through the bundled `cmux` CLI and the app
socket: 40 workspaces, 200 tabs, one shown workspace with 12 TUI panes in seeded columns and rows plus
a browser pane and an agent chat pane (the terminal stand-in when the build cannot open the chat; the
manifest says why). It writes `heavy.json` (ids, which pane runs what, refusals, a `snapshot.get`
check) after each step; `teardown` closes what it made and stops its page server. `heavy_profile.py
plan` prints the plan with no app.

Background load for TYPING UNDER LOAD (`load_profiles.py`, each one command, each runnable at the same
time as the others; never moves focus; only the `--app-socket` named, and never the shipped bundle):

```bash
L=scripts/journeys/tui-kit/load_profiles.py
python3 $L run L1 --app-socket SOCK --home HOME --keep PANE --seed 7 --duration 120 --rate 100  # CLI storm
python3 $L run L2 --app-socket SOCK ...      # 4 MCP clients back to back (no REPL tools: shared host socket)
python3 $L run L3 --app-socket SOCK --keep PANE ...   # 30 browser tabs, 4 beside PANE, page clicks via cmux browser
python3 $L run L4 --app-socket SOCK [--acp] ...       # 6 streaming agent panes (terminal; --acp tries chats)
python3 $L run L5 --app-socket SOCK ...      # the heavy profile, --no-focus
python3 $L run L6 --app-socket SOCK --keep PANE ...   # L1..L5 at once
```

Each prints `LOAD-READY <L> t_mono= t_wall=` when the load is at full rate and `LOAD-DONE <L> ...` at the
end, and writes `<out>/<L>/manifest.json`, `calls.jsonl` and `focus.jsonl` (the focus guard). The module
docstring has every rule; `test_load_profiles.py` checks them against a stand-in app.

The fleet check (no app, no GUI): `cmux-ci run --class exclusive --script
scripts/measure/tui-kit-selftest.sh --ref SHA` runs the tests with the Mac's Python and reports the
gradient's pace.

## Not supported yet

- Generated journeys: one per action catalog row, settings schema entry and keyboard shortcut
  (planned as a generator writing `journeys/generated/`; P0 is hand-written now).
- Pointer journeys beyond window and divider drags, pane clicks (`ext_window.py`) and sidebar Home
  and workspace-row clicks (`ext_multiwindow.py`): tab drags, the green button.
- The Dock's reopen (`applicationShouldHandleReopen`, only with no window visible): no debug method
  drives it, so `mw-new-window-entrypoints` does not cover it.
- Display and scale changes during a resize (`debug.simulate.display` exists; no step yet).
- Pointer in the pane: the `mouse` and `select_text` steps cover wheel, clicks and text selection
  (scroll-paste group).
- Relaunch through `capture-host relaunch`: the driver runs on the mini, so its `relaunch` step opens
  the bundle itself (as `restore-journey.py` does); `capture-host release` still ends every process
  of the lease root. The full restore matrix (browser pages, agents, update and reboot variants)
  stays in `restore-journey.py`.
- Sleep and wake.
- macOS 14 and 15: capture minis run the fleet's macOS; use `scripts/cmux-next/os-matrix.sh`.

## Why

From the cmux-ad handoff "Holistic quality" (Lawrence, 2026-10-27): v1 shipped with Ctrl+C and
live resize broken because no agent typed in a terminal or resized a window before handing it
over; v2 dropped both fixes; many PASS results were pixels-changed, blank frames or fixture text;
and the author judged its own work. Each P0 journey and the gate exist to make those mistakes
impossible to repeat.
