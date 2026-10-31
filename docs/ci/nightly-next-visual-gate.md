# cmux NEXT nightly: visual gate

Before a cmux NEXT nightly is published, the visual gate opens a DEV build of
the same commit, drives it to a few busy states, takes light and dark stills of
its window, and checks the pictures. A build whose window shows a visible
layout miss fails the gate. Once the gate enforces, that build isn't published.

The canary ([nightly-next-canary.md](nightly-next-canary.md)) proves the signed
app launches and works. It doesn't look at the window. The gate does.

## What it checks

`scripts/cmux-next/visual-gate/visual_gate.py` runs these checks on each
state's `light.png`, `dark.png` and `result.json`:

| Check | Fails when | Catches |
| --- | --- | --- |
| steps | A step that isn't `optional` failed, the capture logged an error, a still is missing, or a state in `states/` has no capture at all. | A state the build can no longer reach, such as a debug verb that times out. |
| appearance | `light.png` and `dark.png` are the same picture: under 10% of pixels changed and about the same mean brightness. | A window that doesn't repaint when the appearance changes. |
| seam | A 1-2 px line of one neutral colour runs through 60% of the window's height or width and contrasts with both sides. | A gap between layers that shows through, such as the black line through the Chief pane. |
| overlap | Two text boxes overlap, or one line reads much taller than the window's other lines and stays garbled when read again on its own. | A panel drawn see-through over chat text, or a pill drawn over a message. |
| scale | The stills are below 2x. This is a warning unless the 2x switch is on (see below). | Hairline misses that a 1x still hides. |

Each finding has a level:

- `fail` blocks publication in enforce mode.
- `host` is a problem with the capture Mac's own configuration. The finding names the Mac, and it never blocks.
- `warn` and `info` are notes.
- `error` means the gate couldn't judge that state, for example because a
  still or `result.json` couldn't be read. The other states are still judged.
  A run with errors and no `fail` gets the verdict `unavailable`, never `fail`.

### Same picture in light and dark

A light still can match the dark one because the Mac's own configuration is
wrong, not the build. For example, a capture mini whose shared
`~/.config/cmux/cmux-next.json` pins a dark-only theme turns every light still
dark. Before it blames the build, the gate reads what the app reported after
each switch. The capture asks `debug.appearance` once the switch settles and
records the effective appearance, the terminal background and the themes
folder in `result.json`.

| What the app reported | Level |
| --- | --- |
| The app stayed dark after switching to light. | `fail` |
| The app bundle ships no Ghostty themes. | `fail` |
| The terminal stayed dark while the app ran on its own settings file. | `fail` |
| The theme switched, but the window didn't repaint. | `fail` |
| The terminal stayed dark while the app ran on the Mac's own settings file. | `host` |
| The capture recorded nothing from the app, as with older HQ `pr-capture` output. | `host` |

The nightly job always launches the app with its own settings file, so a
setting on the Mac can't leak into the stills. Another Mac's configuration
belongs to whoever runs that Mac, so report it to them rather than editing it.

### Stills below 2x

`debug.window_snapshot` draws at the display's backing scale. The scale is
1x on displays without HiDPI, so a 1100x720 pt window gives a 1100x720 px
still. The gate measures the scale (pixels over the window's width in points)
and warns below 2x. Set the repository variable
`NIGHTLY_NEXT_VISUAL_GATE_REQUIRE_2X=1` once the capture Macs have a HiDPI
display; stills below 2x then fail.

### Text over text

When two pieces of text are drawn on top of each other, macOS text
recognition rarely returns two overlapping boxes. It reads them as one line
that is taller than its neighbours and garbled.
`scripts/cmux-next/visual-gate/ocr_boxes.swift` prints every line's box and
its unknown words. It also cuts each line out, scales it up 3x and reads it
again.

- Two wrapped lines that Vision ran together read cleanly, one above the other.
- Text drawn over text stays garbled, or comes back as lines on top of each
  other.

A word cut off at a pane's edge and product names such as `cmux` and
`acpmux` aren't counted as garbled. A tall line fails only on two unknown
words, or on one that the reread reads differently. A large heading with one
jargon word reads the same both times, so it passes. This matters because the
spell checker's word list differs from Mac to Mac.

## How it runs

Four jobs in `.github/workflows/nightly.yml` run beside the signed build.
They run only for the `nightly-next` track. In enforce mode, `publish-nightly`
waits for the gate's verdict, but never more than 10 minutes past the signed
build being ready. Usually the signed build and notarization take longer, so the
gate adds no time. When the gate takes longer (a cold DEV build took 35 min), it
delays publication by the difference, up to that bound. Outside enforce mode,
publication doesn't wait for the gate at all.

1. `route-visual-gate-nightly` (Linux) resolves the mode and picks the runner.
   - The mode comes from the canary's resolver,
     `scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE`.
   - The runner comes from the media tour's picker,
     `scripts/ci/cmux_next_media_runner.py --idle-now`. It reads the runners
     live with the route App's token, as `side_lane_placement.py` does. It
     takes an owned Mac's session runner that is idle right now, or else an
     idle gui runner. Those runners hold the logged-in console session the
     app draws in. Workflows never name an owned label
     (`tests/test_ci_self_hosted_guard.sh`).
   - When no such runner is idle, or the runners can't be read, the gate is
     skipped with the verdict `unavailable`, and the job summary says why. A
     self-hosted job that queues can wait up to a day, so the gate never
     queues for a busy runner. A runner taken (or gone) between the pick and
     the job's start still leaves the gate queued; step 3 stops publication
     from waiting for it.
   - The owned-pool rescue (`scripts/ci/owned_pool_rescue.py`) watches only
     `build-nightly-app` in a nightly run. The gate waiting for a runner never
     gets the run cancelled, which would kill its notarization.
2. `visual-gate-nightly` (the owned Mac) runs these steps in order:
   1. Builds the DEV app of `build_sha` with the same cmux-tui tree as the
      signed build. It uses a warm media tour slot (`media_tag_lock.py`,
      `media_build_app.sh`).
   2. Captures every file in `scripts/cmux-next/visual-gate/states/`
      (`capture_states.py`, which drives the app through `media/tour.py`'s
      `App`). A state that can't launch records its error and the next state
      runs.
   3. Reads the text boxes. Each state's boxes are written only when the read
      succeeds. A failed read leaves none, so that state's overlap check
      can't run: the state is an `error` (not judged), and a run with no
      `fail` is `unavailable`, never a pass.
   4. Runs the gate with `--states`, so a state that was never captured
      fails. Exit 1 is `fail`. Exit 3 (a state couldn't be judged) and exit 2
      (bad input or a crash) are `unavailable`.
   5. Uploads the stills and the report as `nightly-next-visual-gate-<sha>`
      (3 days).

   The findings go in the job summary. When the verdict holds the build
   (enforce mode, `fail`), its `Hold publication` step runs.
3. `visual-gate-nightly-verdict` (Linux, `actions: read` only) is what
   `publish-nightly` waits on. GitHub can neither cancel one job nor bound
   its queue time, so this job reads the gate's job in the run attempt
   (`nightly_next_canary_mode.py await-gate`) once a minute. On a run's
   first attempt it starts only once the signed build is ready (it needs
   `verify-final-dmg-nightly`), so the gate has had the whole build to get a
   runner and finish. Its budgets run from when that check finished, by
   GitHub's timestamps, so time this job spends waiting for its own Linux
   runner counts against them, and a hold counts only when the gate itself
   finished within them:
   - Outside enforce mode it waits for nothing: no verdict can hold the
     build, so the job ends at once with the verdict `report`.
   - Still waiting for a runner 5 minutes after the signed build was ready
     (the queue budget): the verdict is `unavailable`, a warning and the job
     summary say this nightly publishes unchecked, and publication goes
     ahead. Nothing is cancelled; the gate still runs if a runner frees up,
     and its verdict is still recorded.
   - Started: it waits for the gate to finish, at most 10 minutes past the
     signed build (the hold). `blocks` is `true` only when the gate's `Hold
     publication` step succeeded. A held build fails this job too, so "Re-run
     failed jobs" retries the gate and this job together and the retried
     verdict decides. A re-run starts the gate beside this job, so there the
     gate gets the full 15-minute queue budget and its 75-minute timeout:
     a re-run never publishes a held build unchecked for want of time.
   - Missing, never finishing, or the API unreadable after 5 tries:
     `unavailable`, and publication goes ahead.

   It has the gate's `needs` and `if`, so it is skipped exactly when the
   gate is.
4. `report-visual-gate-nightly` (Linux) records each judged build in the
   `nightly-next visual gate` issue. It opens the issue if none is open. Each
   build gets one comment whose first line is
   `cmux NEXT visual gate passed|failed <build sha>: <run>`. This issue is the
   gate's record: the recovery path and the auto flip read it.

`publish-nightly` needs `visual-gate-nightly-verdict`, never the Mac job
itself. It doesn't publish this run's own build when that job's `blocks`
output is `true`, which means enforce mode
and a failing verdict. Publication goes ahead as before in every other case:
report mode, a skipped gate (no owned session runner idle, mode `off`), a
gate that couldn't capture or judge, or one that queued past its budget
(`unavailable`, reported as a warning).

The gate fails closed on its own configuration. When the mode can't be
resolved (an invalid `NIGHTLY_NEXT_VISUAL_GATE`, or the resolver crashing),
`route-visual-gate-nightly` gives the mode `invalid` with an error: no gate
runs and `publish-nightly` doesn't publish this run's own build. Set the
variable to `report`, `enforce`, `off` or `auto` to publish again. A failure
outside the gate never holds a build this way.

A build whose notarization was still pending can be published later by
another run, through `find-nightly-next-recovery` →
`recover-nightly-next-notarization` → `publish-nightly`, or by a
`nightly_next_continue_only` dispatch. Such a build is judged by its own
recorded verdict, not by the gate of the run that recovers it.
`find-nightly-next-recovery` reads the verdicts from the issue (the last 14
days; `nightly_next_canary_mode.py verdicts`). For each candidate, the
continuation runs `nightly_next_canary_mode.py admit`:

| Mode | Verdict of that build | Result |
| --- | --- | --- |
| `enforce` | `fail` | Refused, and the next candidate is tried. |
| `enforce` | `pass` | Published. |
| `enforce` | none (skipped, `unavailable`, or the issue can't be read) | Published, with a warning. |
| `report`, `off` | any | Published. |

The run's own `blocks` holds only its own build, never a recovered one.
When the mode can't be resolved, recovery reads it as `enforce`: a build
the gate recorded as failed is refused and any other is admitted.

HQ's `cmux-ci capture` (`build-fleet/pr-capture`) takes the same stills on a
fleet capture mini. It needs an HQ checkout, SSH to the `cmux-mac-mini-cua*`
hosts and a tailnet identity, and no Actions runner has those today. Its
output has the same shape, so you can gate it by hand:

```bash
python3 scripts/cmux-next/visual-gate/visual_gate.py ~/.cache/pr-capture/<sha8>/<state>
```

## Mode

`NIGHTLY_NEXT_VISUAL_GATE` is a repository variable:

| Value | Effect |
| --- | --- |
| `report` | Captures and reports; never blocks. |
| `enforce` | A failing verdict stops publication. |
| `off` | Skips the gate. |
| unset or `auto` | Reports until `NIGHTLY_NEXT_VISUAL_GATE_ENFORCE_AFTER` (default 2026-10-28T16:00Z), then enforces. It enforces only if, in the week before that date, the gate failed no build and passed at least 3. Otherwise it stays in report until someone triages it and sets `enforce` or moves the date. |

This is the canary's one-week flip, read from this gate's own issue, plus a
minimum of passes (`--min-passes 3`). A week in which the gate was mostly
skipped proves nothing about the gate. The canary itself needs no passes.

## Add a state

A state is a JSON file in `scripts/cmux-next/visual-gate/states/`:

```json
{
  "title": "What the window shows",
  "settings": null,
  "launch_args": ["--showcase"],
  "steps": [
    {"title": "seed the showcase", "rpc": {"method": "debug.showcase.seed", "params": {"focus": true}}, "wait": 6},
    {"title": "maybe", "cmux": ["agent", "new-chat"], "optional": "agent backend unavailable"}
  ]
}
```

- `settings` is the `cmux-next.json` the app launches with. `null` means none,
  never the Mac's own file.
- `--showcase` also sets `CMUX_NEXT_SHOWCASE=1`.
- A step has at most one `cmux` argv or `rpc` (a step with neither only
  waits), an optional `wait` (0-30 s), `optional` set to `true` or a reason,
  and `cite`, the handler's file:line (documentation only).
- A state whose required step fails fails the gate, so check in only states
  that have run cleanly at least once.

To check a state file, run this on any OS:

```bash
python3 scripts/cmux-next/visual-gate/capture_states.py --check scripts/cmux-next/visual-gate/states
```

The same file works as `cmux-ci capture SHA --state FILE` on a fleet capture
mini, which is the quickest way to see a new state before it gates a nightly.

## Tests

`tests/test_cmux_next_visual_gate.py` runs on Linux in `ci-guards.yml`. It
covers:

- every check on synthetic stills and on text-box fixtures taken from real
  3a63d6d9 captures;
- the light/dark attribution;
- the 2x switch;
- a bad still, an empty text-boxes file or a malformed `result.json`, each
  kept to its own state, and states that were never captured;
- the mode resolver under the gate's variable, with the 3-pass minimum, and
  each build's verdict as recovery reads it;
- the idle-runner pick;
- the queue escape: a gate left queued after its runner was taken, a gate
  that starts in time, a missing gate and an unreadable API;
- `capture_states.py` against a fake app and an unreadable bundle;
- the `nightly.yml` wiring.

`tests/test_ci_owned_pool_rescue.py` covers the rescue never cancelling a
nightly run for the gate.
