# Human-like agent mouse (cmux-next browser use)

User, 2026-10-20: "for the browser, for moving the mouse around, we need to
make it feel more human. Think from first principles about how we can make
the mouse movement feel more human, both to the website itself and as an
animation to the human."

Owner: the "Human-like agent mouse" subagent. Neighbours: a201 owns the cursor
*shape*; a356 owns "agents never take over the user's tab". This doc owns
the cursor's *motion* and the page's *event stream*.

## Two audiences, one path

There are two consumers of an agent pointer move:

1. **The website.** It sees DOM events: `pointermove`/`mousemove`,
   `pointerover`/`pointerenter`/`pointerout`/`pointerleave` as the pointer
   crosses elements, then `pointerdown`/`mousedown`, `pointerup`/`mouseup`,
   `click`. Bot detectors and ordinary pages (hover menus, tooltips,
   drag-to-reveal, canvas apps) read the *shape* of that stream: how many
   moves, their spacing in time and space, whether the pointer hovered
   before pressing, how long the press lasted.
2. **The person watching.** They see the agent cursor overlay
   (`CmuxNextAgentCursor`), which draws from the `automation.input` events
   the browser host publishes for each dispatched input.

Today both are wrong in the same way: `locator.click` and `mouse.click`
send **one** `move` at the target, then `down` and `up` back to back.
The page sees a pointer that teleports, never hovers anything on the way,
and presses for ~0 ms. The overlay hides the teleport with its own glide
(`GlideMotion`, straight line + spring), so what the person sees is not
what the page got.

**Decision: one planned path drives both.** The REPL runtime plans a human
path once per move and streams it to the engine at display rate. The
browser host already publishes one `automation.input` `move` per
dispatched `input.mouse` move, so the overlay receives the same samples
the page did and only has to *follow* them. No schema change, no second
planner that can drift from the first.

## The model (first principles)

Human aimed movement is well described by four facts from motor-control
research; each maps to one parameter.

| Fact | Model | Parameter (`agentMouse.*`) |
|---|---|---|
| Time grows with the log of distance over target size | Fitts's law, `T = a + b·log2(D/W + 1)` | `fittsA` 50 ms, `fittsB` 90 ms, `targetWidth` 24 px |
| Speed is bell-shaped: slow start, fast middle, slow arrival | Minimum-jerk profile `s(τ) = 10τ³ − 15τ⁴ + 6τ⁵` | (fixed) |
| Paths are slightly curved, not straight | Cubic Bézier with both control points displaced to one side by 0–12 % of `D` | `curvature` 0.08 |
| Long aimed moves are a fast primary move that misses a little, then a slow correction | Primary sub-movement ends 3–6 % short (60 %) or 2–4 % past (40 %), then a second minimum-jerk sub-movement to the target | `correctionMinPx` 120 |
| The hand is never perfectly still | Smoothed perpendicular tremor, ≤ 0.5 px, zero at both ends | `jitterPx` 0.5 |
| People hover before they press, and a press lasts | Dwell before `down` 40–110 ms; hold 50–110 ms; double-click gap 70–140 ms | `dwellMs`, `holdMs`, `doubleClickGapMs` |

**Speed cap.** Agents click a lot, so the whole move is capped:
`T = clamp(fitts, minMoveMs 60, maxMoveMs 350)`. A 1000 px move takes
350 ms, a 100 px move ≈ 230 ms, a 10 px move 60 ms. With dwell and hold, a
click costs ≈ 0.3–0.5 s more than before. `motion: "instant"` restores the
old teleport for scripts that need raw speed.

**Event cadence.** Samples are 60 Hz (16.7 ms, the rate a real mouse
reaches a page after the browser coalesces moves per frame). Points are
whole CSS px (real `clientX`/`clientY` are integers at the page's zoom).
The stream is played against the clock: if a driver round trip is slow,
samples whose time has passed are **skipped** (coalesced, as a browser
does), never sent late in a burst, and the final sample is always sent.
So the move takes `T` wall time, not `T + n·latency`.

**Determinism.** Every random choice comes from a seeded PRNG
(`mulberry32`). The session seeds it once from the clock; tests pass a
seed, so path and timing properties are tested exactly.

**What is not humanized (on purpose).**

- `mouse.move(x, y, { steps })`: an explicit `steps` is Playwright's
  contract (straight line, `steps` events), so it stays linear.
- `force` clicks and `trial` actions keep their Playwright meaning.
- Aim scatter inside the element (people don't hit the exact center):
  the actionability check (`hitTarget`) runs at the center point, so
  scattering would need the check moved to the scattered point. Phase 2.
- Wheel inertia (one `wheel` call split into a decaying series of events
  over ~200 ms, as a trackpad fling): phase 2, because every wheel part
  also draws a scroll mark and records a trace entry.

## Where it lives

- `cmux-tui/crates/cmux-browser-host/js/human-mouse.js` (new, before
  `runtime-core.js` in `manifest.json`): pure planner. `config(overrides)`,
  `rng(seed)`, `moveDuration(D, W, cfg)`, `planMove(from, to, cfg, rand,
  { width })` → `[{ t, x, y }]`, `pause(range, rand)`. No I/O, no clock.
- `runtime-core.js`:
  - `Mouse.move` without `steps` plays `planMove` against `session.now()`
    and `session.sleep()` (coalescing as above).
  - `Mouse.click` and `Page._clickAt` wait `dwellMs` before `down` and
    `holdMs` between `down` and `up` when the caller gave no `delay`,
    and `doubleClickGapMs` between the clicks of a double click.
  - `session.agentMouse` holds the config (defaults merged with
    `host.agentMouse` when a host supplies one); per call
    `{ motion: "instant" | "human" }` overrides it.
- `CmuxNextAgentCursor/AgentCursorOverlayModel.swift`: a `move` that
  arrives within `followWindowMs` (100 ms) of the session's previous
  `move` is a streamed path sample: the cursor **follows** it with a short
  linear segment over the measured gap (`GlideMotion.follow`), with no
  spring, so the overlay traces the page's path frame for frame. A lone
  move or a click after idle keeps the existing glide. Under Reduce Motion
  (`Motion.animatesMovement == false`, the a274 gate) every placement
  snaps: no glide, no follow, no spring.

## Settings

`browser.agentMouse.motion` (`human` | `instant`, default `human`; `instant` in a
headless Chromium tab, which nobody sees: its engine reports the `headless`
capability, and the human path only cost each click 0.4-0.5 s there,
[browser-use-perf.md](browser-use-perf.md)) and
`browser.agentMouse.maxMoveMs` (default 350) are the user-facing keys. The
REPL reads them from `host.agentMouse`. **Not wired yet:** the browser host
(Rust, `cmux-browser-host`) has no path from cmux.json today; slice 2 adds
`agentMouse` to `browser.repl.open` and the Settings rows (with en/ja and
the other locales). Until then the defaults apply and a script can set
`page.mouse.configure({ motion: "instant" })`.

## Tests

`tests/browser-parity/unit/human-mouse.test.mjs` (Node, no browser):

- duration follows Fitts's law, monotonic in `D`, falls with `W`, and
  never exceeds `maxMoveMs`;
- the path starts at the origin, ends exactly on the target, timestamps
  rise strictly at ~60 Hz, and the last sample is at `T`;
- the speed profile is bell-shaped (slow in the first and last 10 %,
  fastest in the middle);
- the path is curved (max perpendicular deviation > 0) but bounded
  (≤ 15 % of `D` + jitter), and long moves contain a correction
  sub-movement (a speed minimum before the end);
- same seed, same path;
- `locator`-style click through `Page._clickAt` on a fake driver sends
  `move…, down, up` with dwell ≥ 40 ms before `down` and hold ≥ 50 ms;
  `mouse.click` from far away sends many moves; `steps` stays linear;
  `motion: "instant"` sends one move and no pauses; a slow driver is
  coalesced (wall time ≈ `T`, final sample still sent).

`CmuxNextAgentCursorTests` (Swift): streamed moves within the follow
window produce linear follow glides with no spring overshoot; under
Reduce Motion every move is a `place`.
