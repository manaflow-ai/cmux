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

Output, in `artifacts/journeys/<job12>-<run id>/` (or `--out`, which must be a new folder):

- `results.jsonl`: one line per journey: `id`, `priority`, `status` (`pass`, `fail` or
  `not run`), `reason`, `evidence` (each check with its result, its time from the mark and
  what it saw), `clip`, `checks` (the frames the checks read), `build_job`, `commit`, `tag`,
  `host`, `path`, `nonce`, `run_at`, `run_id`, `run_started_at`, `harness`;
- `run.json`: the run id (`<UTC time>-<8 hex>`), its start time and the harness checkout;
- `<id>/result.json`: the full record (every step and its reply, every check's detail);
- `<id>/check-NN.png`: each frame a `frame_text` check read (full size);
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

`ext_routing.py` (group focus and input routing, `journeys/dogfood/routing-*.json`, written by
`routing/gen.py`; VIDEO EXTRA item 5) asks where a person's typed text lands after an action that moves the
focus (Cmd-N then Ctrl-\`, Cmd-D, Cmd-W, a click while a split animates, Cmd-1..8, a tab switch). Each attempt
types a unique marker line at once with real HID keys (`key_path=real`, `smoke_type_now`). Condition
`routing_marker`: the line ran on exactly the expected terminal (a named one, the one new since a snapshot, or
the focused one) and no other, and the app shows it in that pane; its detail names the verdict (`right`, `wrong`,
`lost`, `split`, or `unjudged` when the harness cannot name one expected terminal). Steps: `routing_click` (a real
click inside a named pane while it animates), `routing_map_workspace_keys` (set-up: the app's own Cmd-digit of each
named workspace) and `routing_select_workspace`. `routing/tally.py RUN_DIR...` tallies the verdicts.

`ext_typing.py` (VIDEO EXTRA item 1) types N real HID keys at a person's pace (`typing_keys`) and records each
key's post time on the host clock of the HARNESS kit's frames.json; `typing/judge.py` counts the display
refreshes from each key to the first frame that shows its glyph, from the kit's movie.

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
a 1.5 s settle. Then, each from the layout the one before left: New Column (the action) and its key
Ctrl-Cmd-D each add one column, and every existing column (matched by its panes, width from the float
view frames) keeps exactly its width; Cmd-D (Split Right) splits the focused pane inside its own column
(Lawrence 2026-10-01, plans/cmux-next/column-sizing.md; Cmd-D is a Ghostty-reserved key, so a change
needs his own "Ghostty-defaults-OK"): no new column, that column gains one pane, every OTHER column
keeps exactly its width; Cmd-Shift-D (Split Down) adds no column and every column keeps its width
(`smoke_same_widths`; each old and new width in the result). Each old column is measured from its
old panes only, so a pane a split just added (no frame yet) never hides it. Any real problem (a width
change, a lost or extra column, no split in place) fails first. When an old pane has no view frame
(cmux-ad 09:3xZ), the gate tells two cases apart, with the evidence in the result: the terminal is
GONE (the daemon topology has no pane or terminal tab, its screen read fails, the daemon has no
process for it, or that shell process is dead): a FAIL, "TERMINAL GONE under memory pressure"
(a possible P0); or only its view is hidden (daemon pane, screen and shell process alive; proven on
v2.2.11-opt 2026-10-31: the app unmounts the view of a far off-screen column after a second New
Column). A hidden column is then judged by the daemon's own column width (`cmux screen ID layout
export`: `columns[].width`, a share of the viewport) before and after; only when the daemon width
cannot be read is the round not judged. The daemon share is the layout MODEL's width: it cannot see a
hidden column that the app alone draws at another width. GONE needs a clear answer (no daemon pane or
terminal tab, a `dead` tab, a terminal list lifecycle other than running or an exit, a dead shell pid),
read twice; a failed read only leaves the pane unproven. A GONE terminal ends the step at once.

Sources of each check: column membership from the app's topology (`snapshot.get`, each pane's
`column`); column widths from the app's terminal view frames (`debug.surfaces` `grid.frame_x` and
`frame_width`), and for a hidden column from the daemon's layout (`columns[].width`); terminal sizes from `debug.surfaces` (grid, fit_grid, drawn_grid, frame and cell size),
the daemon (`cmux terminal ID screen read`: cols, rows), the topology tab (columns, rows) and the PTY
(`stty size`); terminal life from the daemon (`cmux terminal ID process show`) and the process table.

**No pass without the resize checks** (cmux-ad 06:38Z): a round passes only when it reached and passed,
exactly once each, the 2 R3a checks and the 5 R3b checks (the last, from the action fuzzer's case,
in its own fourth workspace after the reopen: Cmd-N, Ctrl-` and a line, then Ctrl-Cmd-D as its first new
column) (`REQUIRED_CHECKS` in smoke-gate.py: their
exact titles; a renamed or duplicated check never counts). A round whose journey passed without them
is a FAIL that names the missing checks; a round that failed at an earlier step stays a FAIL; a round
that did not run (no lease, a known gap, a column width that cannot be read) stays NOT JUDGED. None is
ever a pass, and the `.pass` file needs every round to pass.

**A check that cannot be judged does not end the round** (lead 10:1xZ): the journey has
`continue_not_judged`, so an expect step that is not judged (a hidden view whose terminal lives, a
host prompt) is recorded (`ok` null, `not_judged`) and the journey goes on to every later step; the
round is then "not run" (never a pass), unless a later step fails. The last step
(`smoke_no_key_gaps`) makes a round with a key-window gap "not run" also under a plain run.py.

**Typed at once** (`smoke_type_now`): no wait for the creation hold, the case Lawrence reports
(keys into a terminal while it is created). A capture slot's window is never key
(`CMUX_NEXT_NO_ACTIVATE`), and held keys are replayed through `NSApplication.sendEvent`, which
reaches only the key window. So the journey first makes its window key without activating the
app (`smoke_make_key`: `debug.window.focus`, which calls `makeKey()` and reports the key window),
and each check and each type-at-once step reads that a main window is still key
(`smoke_key_window`, `debug.window_list`; not key before typing: known gap).
A step that leaves a Chromium page focused (Cmd-T's New Tab page) says `smoke_key_window {"page": true}`:
the page's `CefNSWindow`, a visible child of the cmux window, then holds the keys, as the app is built to do
(`ChromiumPageWindowMain`). Every other step wants the main window itself key.
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

### The daemons must be the build under test

The cmux-tui owner and the acpmux daemon outlive the app, so a round can run a new app against an older daemon
(#27829). At the end of each journey the driver records, in result.json's `daemons`, the build under test (the
bundle's `cmux --version --json` build_identity) and, for the cmux-tui owner the app is connected to (`identify`:
pid, build_id, cli_path) and the acpmux daemon it runs (`agent.acpmux` socket, the server's `initialize` `_meta.acpmux.build`
and its executable), each one's pid, executable and build. The daemons are sampled after the journey's first step, after each
relaunch and at the end. A pass or a fail is "not run" when any sample shows a daemon of another binary or another
build. When the cmux-tui owner cannot be verified at the end (no answer), a pass is "not run" but a FAIL stays a
FAIL, with the facts in its reason: a daemon that died, hung or quit during the round is the finding. bin/acpmux
of the same bundle (a symlink, hard link or copy of bin/cmux) is the build; no acpmux running is fine. Tests:
`test_daemon_skew.py`.

### Real HID keys in the gate (`key_path=real`)

`debug.key` enters the app's key router directly: it skips the window server, AppKit, the menu's key equivalents
and the responder chain, so a bug there (with the command palette open, a real Ctrl-` made no terminal, STATUS
1456) cannot fail the gate. So each gate run types at least 2 of its 10 rounds (rounds 1 and 6) with REAL key
events: `--journey-option key_path=real` makes the smoke journey's `smoke_key`, `smoke_type` and `smoke_type_now`
steps send each key through one CuaDriver MCP session (`press_key` / `hotkey` with scope desktop: a key event
posted to the window server's HID stream, which goes to the frontmost app as a keyboard's does; about 11 ms a key,
where the window-targeted modes front and restore the window for every key, about 0.4 s), Cmd-N, Ctrl-`, Cmd-D,
Cmd-T, Cmd-W and every typed line included. Before each key or line the app must be the frontmost app
(lsappinfo); another app in front is not run (the host's limit). Real keys need a whole-host lease (`--whole-host`); without one a run has no real-key rounds and is a
trial. Each step's `key_path` in result.json says which path its keys took (`real_hid` or `debug.key`; relaunch's
Cmd-Q stays `debug.key`). A real-key round whose basic keys did not all take `real_hid` is not run; a .pass needs
the real-key rounds to pass. A key CuaDriver refuses is not run, never a red of the build. `--real-key-rounds N`
asks for more.

### Open P0 journeys block the .pass

A build with an open P0 that the smoke journey does not test would pass by omission (cmux-ad 12:35Z). So after
10 of 10 rounds the gate also reads `handoff/open-p0-journeys.txt` (one open P0 per line: journey ids, `a|b` for
any one of them, the kit branch@commit, the owner and the STATUS item that opened it) and the ledger
`handoff/open-p0-results/<JOB>.jsonl`, to which every `run.py` run appends its results. The `.pass` is written only
when each listed journey has a PASS and no FAIL on that exact build job; else the gate writes `open-p0.txt` in its
out folder, naming each blocking line, and exits 75. Owners add a line when a P0 opens and remove it only when the
fix is in the build and the journey passes. A kit whose `run.py` predates the ledger: append its `results.jsonl`
lines to the ledger file. `--build` must be the full job id. Only a PASS of a clean journeys tree in the judged mode
(not `smoke_mode=diagnostic`) counts. A FAIL shown to be the kit's own false red is waived by a line
`<the row's out path> <reason>` in `handoff/open-p0-waivers.txt`; the waiver is named in `open-p0.txt` and the `.pass`.

### Rounds by scheduler GO (`--go-spec`)

When the mini scheduler gives one round per GO (lead, STATUS 1354), `--go-spec NAME` keeps all rounds in one
gate run: before each round the gate waits for a new GO in `mini-queue/rounds/NAME.go`, runs the round on the
GO's mini (it must be one of `--hosts`), sets capture-host's acquire timeout and exclusive drain so the lease
starts before the GO's `until` (less 20 s), and writes `NAME.done` after the round, only while that same GO is
still open. A GO with less than 60 s left, or on another mini, is given back unused; one GO is never two rounds.
With `--whole-host`, each round leases the GO's whole mini. No GO within `--go-wait-hours` (4): that round is
not run. The 10-of-10 rule and the `.pass` file are unchanged. A round that took its lease counts as one of the
spec's rounds whatever its status, so give the spec no `rounds` limit, or one larger than `--rounds`.

### Building a smoke candidate (the only way)

```bash
scripts/journeys/build-smoke-candidate.sh SHA [--tag TAG] [--dry-run]
```

cmux-ad 2026-10-31 08:15Z: a plain Release build has no `debug.*` socket, so the gate cannot drive it
(every round stops at step 1, `debug.windows: method_not_found`). Every smoke candidate, feat or
perf, is built like the dogfood lines: `cmux-ci build cmux --release` of a tag that
`Resources/build/cmux-next.dogfood.conf` names, which `reload.sh` builds as the bench configuration
(Release optimization plus `CMUX_BENCH_HOOKS`; it never ships). The script adds that mapping (commit
`c6d35671018`, no app source change) to SHA when SHA lacks it, pushes it as
`cp/smoke-candidate-<sha12>` (a dogfood line, never merge), submits the build and prints the job id
for `smoke-gate.py --build JOB`. `--dry-run` shows the commit and the build command without pushing.

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
