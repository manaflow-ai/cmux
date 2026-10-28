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

Capture hosts come from the fleet registry (`~/.ssh/config.d/fleet-registry.json`, written by
leo-workspace `tools/reach --install`). On a machine without it, name them:
`--hosts "cmux17 cmux18 cmux19 cmux21 cmux22 cmux23 cmux24"` (sets `CAPTURE_HOST_SLOT_HOSTS`).
`JOURNEYS_EXCLUDE_HOSTS` (default `cmux16`) are never leased.

Output, in `artifacts/journeys/<job12>-<UTC time>/` (or `--out`):

- `results.jsonl`: one line per journey: `id`, `priority`, `status` (`pass`, `fail` or
  `not run`), `reason`, `evidence` (each check with its result, its time from the mark and
  what it saw), `clip`, `clip_frames`, `clip_action_frames` and `clip_action_distinct` (how
  many of the clip's frames, and how many different ones, show the journey's action), `action`
  (its first step and its start and end times), `checks` (the frames the checks read),
  `build_job`, `commit`, `tag`, `host`, `path`, `nonce`, `run_at`;
- `<id>/result.json`: the full record (every step and its reply, every check's detail);
- `<id>/check-NN.png`: each frame a `frame_text` check read (full size);
- `<id>/clip.mp4` (with ffmpeg) or `<id>/clip.png` (an animated PNG, about a frame a second;
  any browser plays it) and `<id>/clip/`, the frames it is made of. Every frame is in the clip:
  frames change size when a journey places, resizes, zooms or fills the window, so the clip's
  canvas is the largest frame and a smaller frame is centered on black.

A journey's action starts at its first step that is not set-up (`new_terminal`,
`neutral_prompt`, `name_pane`, `window_place`, `remember`, `expect` and the like; `SETUP_STEPS`
in `driver.py`). The driver takes a frame as the action starts and one as it ends, besides the
frame every `--frame-interval` seconds, so a 1-second journey still has its action in the clip.
`run.py` turns a `pass` into a `fail` when the clip shows fewer than 2 different frames of the
action, or there is no clip.

Exit 0 when every selected journey passed, 1 when one failed, 75 when none failed but one did
not run.

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
3. The slot downloads the build's artifact (`cmux-ci artifact JOB`) into the lease root, and
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
| the frame | `debug.window_snapshot` (the app's own drawing of its main window) read with macOS text recognition |

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
| `new_terminal` | `via`, `name` | `via: "key"`: the person's New Terminal Tab key (Ctrl-\`, newSurface) through `debug.key` (origin user: it claims the window's keyboard), then as `focused_terminal`; use it in every journey that plays what a person does. `via: "socket"` (the default, kept for older journeys): `action.run newTab` named `name` (focused); waits for the new focused terminal pane and its first prompt; later steps use that terminal |
| `script_new_terminal` | `name`, `focus` | automation on purpose: a script's `action.run newTab` through the socket; waits for the topology to list workspace `name` with a terminal and its first prompt, without waiting for it to show (a script's newTab does not take a text input the person has: cp/fix-chief-composer-focus) |
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
| `relaunch` | `how` (`quit`, `crash`), `mark` | ends the app and opens it again as a person does: `quit` presses Cmd-Q (a quit sheet gets its default, as Return); `crash` is `debug.crash.app` (SIGSEGV in the app). Then `open -g -n -a` the same bundle with its launch variables (the slot's HOME, socket, settings file), waits for the new process and the loaded topology, and finds every named terminal again. `mark` is the moment the old process ended. `leftovers_after: S`: S seconds after the old process ended (before the reopen), lists every process of the bundle (its path, or `--owner BUNDLE_ID`) for `quit_leftovers` |
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
the terminal, or, after `focused_terminal`, after the terminal showed its prompt (checks do not
wait): keys pressed while a creation is pending wait in its hold and run one creation at a time,
so a burst's last terminal (19 Ctrl-\` presses) is made, and its hold starts, long after the last
key. Typing ahead into a terminal still being made is not covered by journeys in a slot.

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
| `{"frame_text": "TEXT"}` | frame | a fresh snapshot of the window shows TEXT to text recognition (spaces dropped, look-alike letters folded) |
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
| `{"daemon_terminal_gone": "N"}` | daemon | the daemon's terminal list has no terminal N, or its lifecycle says it ended (`exited`, `closed`, `dead`): a shell that exited closed its terminal |

`within` (seconds) makes a timing claim: each condition must first hold within that long of
`since`, or it fails with the measured time. Frame checks are read after the other conditions
hold (text recognition takes about a second) and do not count against `within`.

### Step groups (`ext_*.py`)

A group's own steps and conditions live in `ext_<group>.py` beside `driver.py`; the driver loads
each one (`load_extensions`) and `run.py` sends them to the mini with it. A group file has
`install(driver)`, `STEPS` and `CONDITIONS` (name to evidence kind and function), must not import
`driver.py`, and may not redefine a step or condition. A journey may have `finally` steps (put the
app back for the next journey: leave full screen, close a second window, restore the window
frame); they run whatever happened and never change the status.

A group may list its negative conditions in `NEGATIVE` (read every poll and through `settle`, as
`*_lacks` are).

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

A text check reads output, never the typed command: the command says `X-${nonce}-$((6*7))` and
the checks want `X-${nonce}-42`, which only the shell's output has. The command line's echo of
`X-${nonce}` alone can no longer pass a window or split journey.

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

## Gate a dogfood build

```bash
python3 scripts/journeys/dogfood-gate.py --build JOB
```

It refuses (exit 1) and prints the build report unless:

1. every commit in `dogfood-fixes.list` is an ancestor of the build's commit (add each dogfood
   fix there in the commit that lands it);
2. every P0 journey's newest result for JOB (any `results.jsonl` under `artifacts/journeys`,
   `--results`) is `pass` on the build's commit, with passing app, daemon and frame evidence,
   its check frames on disk, and a clip on disk with at least 2 different frames of its action
   (results written before `run.py` counted action frames refuse: rerun them); and no attempt
   of that journey on JOB under `--results` failed: a rerun that passes does not undo a failure
   (the gate reports it as `flaky`). Move a failure that was the harness's own fault out of
   `--results`, and say why in the build report;
3. the independent QA verdict file `artifacts/journeys/qa/<JOB>.json` (`--qa`) says ship for
   this exact build.

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
  "tried": [{"what": "typed in a new terminal", "result": "pass", "evidence": "path of a still"}],
  "bugs": [{"title": "...", "repro": "1. ... 2. ...", "severity": "high|medium|low",
            "journey": "journeys/p0/NEW.json (or what the new journey checks)"}],
  "notes": "how QA drove the app, its limits, what it did not test"
}
```

The gate refuses the build when the file names no `build_job` or another build, names no
`commit` or another one (a prefix of at least 7 hex digits counts), names no `qa_agent` or the
author, says any verdict but `ship`, lists nothing in `tried`, or has an open bug: any bug of
severity `high`, `critical`, `blocker` or `p0`, and any other bug that names no journey. An
older file's `failures` list is read as bugs too.

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
