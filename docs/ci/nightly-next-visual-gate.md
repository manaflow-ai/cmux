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
| steps | A step that isn't `optional` failed, the capture logged an error, or a still is missing. | A state the build can no longer reach, such as a debug verb that times out. |
| appearance | `light.png` and `dark.png` are the same picture: under 10% of pixels changed and about the same mean brightness. | A window that doesn't repaint when the appearance changes. |
| seam | A 1-2 px line of one neutral colour runs through 60% of the window's height or width and contrasts with both sides. | A gap between layers that shows through, such as the black line through the Chief pane. |
| overlap | Two text boxes overlap, or one line reads much taller than the window's other lines and stays garbled when read again on its own. | A panel drawn see-through over chat text, or a pill drawn over a message. |
| scale | The stills are below 2x. This is a warning unless the 2x switch is on (see below). | Hairline misses that a 1x still hides. |

Each finding has a level:

- `fail` blocks publication in enforce mode.
- `host` is a problem with the capture Mac's own configuration. The finding names the Mac, and it never blocks.
- `warn` and `info` are notes.

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
`acpmux` aren't counted as garbled.

## How it runs

Three jobs in `.github/workflows/nightly.yml` run beside the signed build, so
the gate adds no time to a nightly. They run only for the `nightly-next`
track.

1. `route-visual-gate-nightly` (Linux) resolves the mode and picks the runner.
   - The mode comes from the canary's resolver,
     `scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE`.
   - The runner comes from the media tour's picker,
     `scripts/ci/cmux_next_media_runner.py`. It chooses an owned Mac's session
     runner, or its gui runner until the slots name session runners. Those
     runners hold the logged-in console session the app draws in. Workflows
     never name an owned label (`tests/test_ci_self_hosted_guard.sh`).
2. `visual-gate-nightly` (the owned Mac) runs these steps in order:
   1. Builds the DEV app of `build_sha` with the same cmux-tui tree as the
      signed build. It uses a warm media tour slot (`media_tag_lock.py`,
      `media_build_app.sh`).
   2. Captures every file in `scripts/cmux-next/visual-gate/states/`
      (`capture_states.py`, which drives the app through `media/tour.py`'s
      `App`).
   3. Reads the text boxes.
   4. Runs the gate.
   5. Uploads the stills and the report as `nightly-next-visual-gate-<sha>`
      (14 days).

   The findings go in the job summary.
3. `report-visual-gate-nightly` (Linux) opens the `nightly-next visual gate
   failed` issue, or comments on it, for each failed build.

`publish-nightly` needs `visual-gate-nightly`. It publishes nothing only when
the gate's `blocks` output is `true`, which means enforce mode and a failing
verdict. Publication goes ahead as before in every other case: report mode, a
skipped gate (no owned Mac free, mode `off`), or a gate that couldn't capture
(`unavailable`, reported as a warning).

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
| unset or `auto` | Reports until `NIGHTLY_NEXT_VISUAL_GATE_ENFORCE_AFTER` (default 2026-10-28T16:00Z), then enforces. If the gate failed any build in the week before that date, it stays in report until someone triages it and sets `enforce` or moves the date. |

This is the canary's one-week flip, read from this gate's own issue.

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
- the mode resolver under the gate's variable;
- `capture_states.py` against a fake app;
- the `nightly.yml` wiring.
