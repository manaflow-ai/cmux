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
  what it saw), `clip`, `checks` (the frames the checks read), `build_job`, `commit`, `tag`,
  `host`, `path`, `nonce`, `run_at`;
- `<id>/result.json`: the full record (every step and its reply, every check's detail);
- `<id>/check-NN.png`: each frame a `frame_text` check read (full size);
- `<id>/clip.mp4` (with ffmpeg) or `<id>/clip.png` (an animated PNG, about a frame a second;
  any browser plays it) and `<id>/clip/`, the frames it is made of.

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
| `new_terminal` | `name` | `action.run newTab` (focused); waits for the new focused terminal pane and its first prompt; later steps use that terminal |
| `neutral_prompt` | | writes `PS1='J> '` (zsh and bash), `cd /tmp` and a clear into the PTY through the daemon (set-up, not under test; no host, user or path in any frame) |
| `type` | `text`, `enter`, `mark` | presses each character with `debug.key`, then Return when `enter` |
| `key` | `key`, `modifiers`, `mark` | one `debug.key` (`modifiers`: `control`, `shift`, `option`, `cmd`; named keys: `return`, `escape`, `tab`, `space`, `up`, `down`, `left`, `right`, `delete`, `pageup`, ...) |
| `rpc` | `method`, `params` | one control-socket request (set-up the person does through UI the driver cannot click yet) |
| `wait` | `seconds` | only when nothing observable can be waited on |
| `expect` | `all`, `since`, `within`, `timeout`, `title` | polls every condition in `all` (about every 50 ms plus the reads) until all hold or `timeout` seconds pass |

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

`within` (seconds) makes a timing claim: each condition must first hold within that long of
`since`, or it fails with the measured time. Frame checks are read after the other conditions
hold (text recognition takes about a second) and do not count against `within`.

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

## Not supported yet

- Generated journeys: one per action catalog row, settings schema entry and keyboard shortcut
  (planned as a generator writing `journeys/generated/`; P0 is hand-written now).
- Pointer journeys (drag-resize a window, divider drags, clicks): `debug.mouse` works in a slot
  (`cmux-ci capture` steps use it) but the driver has no step for it yet. The next P0 is live
  resize, the second dogfood v1 bug (scrollback jumped: test 33cd577dcd8, fix 673587c97dc); it
  needs a `mouse` step and a scrollback-position condition.
- Quit and relaunch (session restore) inside a journey: `restore-journey.py` covers it today;
  a `relaunch` step (`capture-host relaunch`) is not written.
- Browser-pane journeys, two windows, display and scale changes, sleep and wake.
- macOS 14 and 15: capture minis run the fleet's macOS; use `scripts/cmux-next/os-matrix.sh`.

## Why

From the cmux-ad handoff "Holistic quality" (Lawrence, 2026-10-27): v1 shipped with Ctrl+C and
live resize broken because no agent typed in a terminal or resized a window before handing it
over; v2 dropped both fixes; many PASS results were pixels-changed, blank frames or fixture text;
and the author judged its own work. Each P0 journey and the gate exist to make those mistakes
impossible to repeat.
