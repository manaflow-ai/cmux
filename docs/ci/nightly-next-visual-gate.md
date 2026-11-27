# cmux NEXT nightly: visual gate

Alongside a cmux NEXT nightly publication, the visual gate opens a DEV build of
the same commit, drives it to a few busy states, takes light and dark stills of
its window, and checks the pictures. A build whose window shows a visible
layout miss fails the gate. Visual coverage is advisory and never holds the feed.

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

- `fail` fails the visual verdict in enforce mode and is recorded for follow-up.
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
They run only for the `nightly-next` track. Publication does not depend on any
of them, so a display queue, capture, or verdict can never delay the feed.

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
     the job's start still leaves the gate queued; publication is independent
     of that queue.
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

   The findings go in the job summary. A failing enforce-mode verdict still
   fails this advisory job so it is visible to follow-up work.
3. `visual-gate-nightly-verdict` (Linux, `actions: read` only) records the
   gate's result independently of publication. GitHub can neither cancel one
   job nor bound its queue time, so this job reads the gate's job in the run
   attempt (`nightly_next_canary_mode.py await-gate`) once a minute. Its
   result is advisory:
   - Outside enforce mode it waits for nothing and records the verdict `report`.
   - Still waiting for a runner 5 minutes after the signed build was ready
     (the queue budget): the verdict is `unavailable`; a warning and the job
     summary say this nightly was published unchecked. Nothing is cancelled;
     the gate still runs if a runner frees up, and its verdict is still recorded.
   - Started: it waits for the gate to finish, at most 10 minutes past the
     signed build. `blocks` is `true` only when the gate's `Hold publication`
     step succeeded; that value is recorded for follow-up and has no
     publication effect.
   - Missing, never finishing, or the API unreadable after 5 tries:
     `unavailable`, and publication goes ahead.

   It has the gate's `needs` and `if`, so it is skipped exactly when the
   gate is.
4. `report-visual-gate-nightly` (Linux) records each judged build in the
   `nightly-next visual gate` issue. It opens the issue if none is open. Each
   build gets one comment whose first line is
   `cmux NEXT visual gate passed|failed <build sha>: <run>`. This issue is the
   gate's record: the recovery path and the auto flip read it.

`publish-nightly` does not need the visual jobs. A mode that cannot be resolved
is still reported as an error, but it cannot hold publication; set the variable
to `report`, `enforce`, `off` or `auto` to restore visual coverage.

A build whose notarization was still pending can be published later by
another run, through `find-nightly-next-recovery` →
`recover-nightly-next-notarization` → `publish-nightly`, or by a
`nightly_next_continue_only` dispatch. Such a build is judged by its own
recorded signed/provenance checks, not by the visual gate of the run that
recovers it. Visual findings remain advisory and are recorded for follow-up.
`find-nightly-next-recovery` reads the verdicts from the issue (the last 14
days; `nightly_next_canary_mode.py verdicts`). For each candidate, the
continuation keeps the notarization and lineage checks; it does not run a
visual publication gate:

| Mode | Verdict of that build | Result |
| --- | --- | --- |
| any mode | any verdict | Published when signing, notarization, lineage and feed checks pass. |

The run's own `blocks` value is recorded for its own build, never used to hold
publication or recovery. Recovery still reads the recorded verdicts so a
follow-up can address a failed build.

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
| `enforce` | A failing verdict fails the advisory visual job and is recorded; publication is unaffected. |
| `off` | Skips the gate. |
| unset or `auto` | Reports indefinitely. Use `report`, `enforce` or `off` explicitly to choose the advisory coverage mode. |

The visual gate's verdict issue remains a record for follow-up. A week in which
the gate was mostly skipped proves nothing about the gate; publication still
uses the signed, notarized, provenance-checked build path.

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
