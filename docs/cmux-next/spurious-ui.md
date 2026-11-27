# Spurious UI: the error classes, and what designs each one out

Leo, 2026-11-24: "this shouldn't show. ive asked for this for a while. we simply shouldnt be running into this
problem if we design out the failure mode/error classes".

**Spurious UI** is anything the screen shows or moves that the person did not cause and that no lasting
state backs: a banner for a condition that cleared before anyone could read it, a guess shown as fact, a row
that moves because something above it arrived late. Each class below has three parts. The **cause** is the
code shape that produces it. The **design-out** is the shared code that makes the class impossible when the
UI uses it, so it is not left to judgement each time. The **detector** is what finds it in a recording or a
test.

The detectors live in [`scripts/cmux-next/flicker-check.py`](../../scripts/cmux-next/flicker-check.py), which
reads a screen recording frame by frame. CI step `recording-shifts` ([`ci/steps.toml`](../../ci/steps.toml))
runs it on seeded recordings that must fail and controls that must pass, so a detector that stops seeing its
class goes red. The same script reports on the app's real recordings (the iOS simulator's `video` runs, the
first-user journey, the Mac media captures) through `recording-shifts-report.py`. Those runs only report and
never fail.

## The classes

| # | Class | What the person sees | Cause | Design-out | Detector (`flicker-check.py` kind) |
|---|---|---|---|---|---|
| S1 | **Flash** | A banner, chip, spinner or notice that comes and goes within a few seconds, and the screen is back as it was | The UI draws a condition the moment it starts (link down, resume, loading, retry) and the condition heals itself | Wait before saying anything: `useAfterDelay` (1.5 s, pause or resume) and `useLinkDownSaid` (10 s, link down) in [`afterDelay.ts`](../../webviews/src/agent-session/acpmux/afterDelay.ts). A state the person can act on (a refused sign-in, an update) is said at once and stays | `flash`: a block of 3+ cells that changes, stays changed and returns to exactly its earlier look after more than a blink (100 ms) and within `--flash-ms` (3 s) |
| S2 | **Blink** | Something drawn for a frame or a few, then gone (mount, unmount, fade out and back in) | Two owners write one state in turn, or a key change remounts a subtree | One owner per visible state ([design-lessons §6](design-lessons.md#6-a-visible-change-is-one-state-transition)) | `blink`: a cell that returns to its earlier value within `--blink-frames` (6) |
| S3 | **Jump** (layout shift) | Rows or a card move in one frame because something above or beside them arrived, grew or left | Content of unknown height is inserted into the flow: a banner above the transcript, a placeholder replaced by content of a different height | Reserve the space, or draw over the flow instead of in it. A placeholder has its content's final size. The bottom stack and composer keep one height across states ([#55238](https://github.com/manaflow-ai/cmux/pull/55238)) | `jump`: a block drawn again moved by 2 px or more in under `--glide-frames` (4) frames, then still |
| S4 | **Staggered settle** | A view arrives in pieces: a frame, then its icon, then its count | Each part loads or measures on its own and draws when ready | Draw once at the final size, from one snapshot ([design-lessons §6](design-lessons.md#6-a-visible-change-is-one-state-transition)) | `staggered`: one burst of change that lands in 3 or more separate steps within 300 ms |
| S5 | **Guess shown as fact** | "Agent may be stuck", "Nudge with hint", a warning on a chat that was fine | A heuristic (silence, a loop counter) rendered as a state | Draw only states the source reports. A heuristic goes to diagnostics, never to the pane ([#45162](https://github.com/manaflow-ai/cmux/pull/45162); the gallery's `NoStuckGuess` stage mounts the real pane with both old "stuck" signals set and expects neither to show) | A gallery stage per removed guess, with the old signal set |
| S6 | **Stale state on revive** | After a relaunch, reconnect or refresh, the last session's banner or rows show, then change | A cached snapshot is drawn as live, then the live page replaces it | Draw the cached copy without its transient notices, and swap to the live page only when both are laid out ([`chatSnapshot/swapDiff.ts`](../../webviews/src/agent-session/acpmux/chatSnapshot/swapDiff.ts); [design-lessons §7](design-lessons.md#7-lifecycle-edges-are-the-normal-case)) | `flash` or `jump` in a relaunch recording (`relaunch-shift-bench.py`, `launch_shift.py`) |

## How the flash detector decides

Frames are scaled to 384 px wide and split into 12 px cells. When a group of 3 or more cells (a caret is one)
changes between two frames, the detector follows that group forward. It reports a **flash** when every cell
in the group comes back within half the change threshold of its earlier value and holds there for 6 frames.
At least half the group must have stayed changed until then, so content that changes into something else is
not counted. The return must take longer than a blink and no longer than `--flash-ms`. Groups that appear
and go in the same frames (a banner and the rows it pushed) count as one flash. A notice that stays, or one
shown for a real outage longer than the window, is lasting state and passes.

The 3 s window sits between the house thresholds. A self-healing pause stays invisible for 1.5 s, and a link
that heals within 10 s never shows at all. A notice seen for under 3 s, with the screen unchanged afterwards,
told the person nothing they could act on.

## What a flash in a real recording means

- A connectivity or progress notice that should have waited: put it behind `useAfterDelay` or
  `useLinkDownSaid`.
- A notice that did wait and then cleared just after it showed (shown at 1.5 s, gone at 2 s). The wait
  stops the notice appearing too early, but not disappearing too soon after. Lengthen the wait for that
  state, or keep the notice up for a minimum time once it shows.
- An acknowledgement of the person's own action (a "Copied" toast, a pressed button). That is not
  spurious: the person caused it. Crop it out with `--crop`, or read the row and move on. The real-recording
  reports never fail a run for this reason.

## Seeded recordings (CI)

[`scripts/cmux-next/tests/test_flicker_check.py`](../../scripts/cmux-next/tests/test_flicker_check.py)

- Must fail:
  - a notice shown for 1 s
  - a spinner for 0.8 s
  - a banner that pushes rows down for 1.5 s and leaves (one flash and two jumps)
  - plus the jump, blink and scaled cases from #55238
- Must pass:
  - a notice that stays
  - a notice for a real 5 s outage
  - content replaced for good
  - a blinking caret
  - a two-frame blink, which stays a blink and is not counted as a flash
  - plus the still, glide and arrive-in-place controls
