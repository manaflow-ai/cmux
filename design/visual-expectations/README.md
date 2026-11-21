# Visual expectations

A UI pull request should reach its reviewer with the visual checks already done, so the only
question left is "do we want this". Leo, 2026-11-14: "be warning against things that differ from
expectation without justification ... just run the whole, you know, ceremony before just doing
like the yes or no decision".

This folder is what the gate judges against:

- `<platform>/<surface>.json`: one file per surface (`web`, `mac`, `ios`). It lists the states to
  capture, light and dark, the tolerance, and the **keep** regions. A keep region is a part of the
  surface that must never change without say-so.
- `baselines/<platform>/<surface>/<state>-<scheme>.png`: the checked-in picture of each state. A
  sidecar `.json` records the keep boxes as captured, and `baselines/<platform>/renderer.json`
  records the renderer (browser version, OS, font set) that drew them.

## What the gate does

`scripts/gallery-matrix/expectations/review.sh N` runs the gate for pull request N.

1. It renders the PR merged into its base on the fleet (`cmux-ci test`; web runs on Linux).
2. It compares each state with the base's baseline at the surface's tolerance.
3. It reads the PR body's `## Visual changes` block.
4. It posts one comment. For each changed state the comment shows **before | after | diff**: one row
   per scheme, with changed pixels in red and keep regions outlined in amber. The PR's
   justification for that state sits beside it.

| Change | No justification | With a justification |
| --- | --- | --- |
| Within tolerance, keep regions untouched | ok | ok |
| Changed, outside keep regions | ⚠️ warns loudly | ✅ explained |
| Changed **inside a keep region** | ❌ fails | ✅ explained |
| A baselined state no longer renders | ❌ fails | ✅ only as `removed` |
| New state, no baseline yet | ⚠️ warns | ✅ explained |
| Head renders differently twice (clock, font or fixture leak) | ⚠️ warns, not judged | same |

The PR is judged by the base's expectations, so a PR cannot loosen its own keep regions. A PR that
edits expectations is listed for say-so. When the renderer changes (a Chrome or font update), keep
failures turn into warnings until the baselines are refreshed.

## Justifying a change

Name each changed surface in the PR body:

```md
## Visual changes
- web/ui.menu: better — the popup adopts the shared transient veil (design/transient-material.md)
- web/ui.notice#error: intentional — Retry moves first, per Leo's ask
- ios/team-appearance: worse — loses contrast on the busy wallpaper; accepted for one look across sheets
```

The ref is `<platform>/<surface id>`. Add `#<state>` to justify a single state; otherwise the line
covers every state of the surface. The verdict is one of `better`, `worse`, `intentional`,
`neutral` or `removed`, followed by the reason. A `worse` change still passes, but the comment marks
it in bold. Whether to accept it is the reviewer's call.

## Refreshing baselines

A justified change also updates its baselines in the same PR, so the next PR is compared with the
new look. Each run's artifact holds `captures/` in the baseline layout.
`bun scripts/gallery-matrix/expectations/gate.ts ... --update design/visual-expectations/baselines`
copies every explained or new state from there into the baselines. To capture this checkout from
scratch, run:

```sh
cmux-ci test --setup webviews --timeout 2400 --artifact /tmp/vg -- \
  bash scripts/gallery-matrix/expectations/fleet-capture.sh here
```

## Adding a surface

Add `<platform>/<id>.json`; `validateSurface` in `expectations.ts` checks it.

- **web**: each capture names a gallery `entry` and `variant` (any `*.gallery.ts` state), plus a
  viewport. Keep regions are CSS selectors, resolved when the state is captured.
- **mac**: each capture names a `stateFile` for `cmux-ci capture`. Keep regions are boxes in points.
- **ios**: each capture names the gallery `launch` arguments (`RecoveryGalleryRoot`). Keep regions
  are boxes in points.

## Determinism

Web states render at device scale 1 in UTC with `en-US` and Reduce Motion. CSS animations and the
caret are off, web fonts are loaded, and the gallery's clock is frozen (`webviews/src/gallery/clock.ts`).
Every state is rendered twice, and one whose two renders differ is reported as nondeterministic,
never as the PR's change.

No GitHub Actions job runs this gate: a lane runs `review.sh` on the fleet.
