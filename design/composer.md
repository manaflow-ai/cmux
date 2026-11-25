# The composer: one spec

This page is the one spec for the agent chat's composer: what it is made of, what it shows at each
width, what never leaves, its glass and shape, and what the hat on top of it says. Every lane that
changes the composer (web, iOS, the hat, the pickers, its buttons, its glass) reads this page first,
builds against it, and changes it in the same PR when a decision moves. The detail pages it points to
keep their own reasoning; this page owns the summary and the order of priorities.

Why one page: the composer was being changed in several lanes at once (the hat, the iOS composer, the
top buttons, the environment picker's glass), each one rediscovering the same width, ergonomics and
glass questions on its own.

Leo's asks it answers:

- Leo, 2026-11-22, on the hat: "the swapping gets jarring. it's too adhd-ish. you need to think hard
  about the various cases, various types of numbers, all that. perhaps there is a case to be made for
  e.g. we dont show the exact calls, ever, at the top."
- Leo, 2026-11-22: "we should consider rounding off our composer and its hat a bit more maybe see
  chatgpt too."
- Leo, 2026-10-14, on the controls row: labels never cut ("Claude Opus …", "Medi…").
- Leo, 2026-10-19: the mic never leaves a row, as in Claude Code: the prompt gives way instead.

## Anatomy, top to bottom

| Part | What it is | Owner page |
|---|---|---|
| Hat (running tray) | Running subagents and background work, tucked into a pill or open as rows | [composer-hat-calm.md](composer-hat-calm.md) |
| Queue | Messages waiting their turn, joined to the card's surface | — |
| Location strip | Where / Machine / folder / branch, on the box's top edge, same fill | [composer-menus.md](composer-menus.md) |
| Box | The prompt, attachments, dictation | [composer-dictation.md](composer-dictation.md), [composer-inline-caret.md](composer-inline-caret.md) |
| Controls row | +, model, effort, permission mode, mic, Send or Stop | `composerRowFit.ts` |
| Quiet foot | Mode, model button and ring under the box (footer look) | `composerRowFit.ts` |

## Widths

The steps are composer widths in `COMPOSER_FIT_STEPS` (`webviews/src/agent-session/acpmux/composerRowFit.ts`).
`composerLocation.css` applies them with `@container composer`, and
`test/composer-fit-steps.test.ts` keeps the two in sync. Change a number there, never in a lane's own
CSS. A narrower composer swaps whole units, never letters.

| Composer width | What changes |
|---|---|
| > 480 px | Everything named: model, effort, permission label, location chips with names |
| ≤ 480 | Location strip tightens (gap 4 px, chips cap at 145 px) |
| ≤ 470 | Effort takes its short name |
| ≤ 460 | Machine chip: icon only |
| ≤ 440 | Model takes its family name ("Opus") |
| ≤ 420 | Permission mode: its glyph only (label in the tooltip) |
| ≤ 370 | Model: its mark only (name in the tooltip) |
| ≤ 340 | Folder cuts in the middle and keeps its last word; the branch keeps its name |
| ≤ 297 | Tight row: group gap 8 px, the card reaches 10 px from the pane's edges |
| ≤ 260 | Tightest rhythm (edge 8 px, inset 4 px); every action stays |

The location strip has its own steps on `@container acpmux-strip`: 396, 340 and 238 px without a
branch chip, and 472, 416 and 314 px with one. See the comment above them in `composerLocation.css`.

The hat steps on `@container running-tray`. At ≤ 400 px a line with a progress line takes two rows,
with its controls on the second. At ≤ 260 px every line does.

A label too long for its step (a long model name, another language) takes the next steps early. The
row measures itself and never flips back across a boundary by a fraction of a pixel.

## Always visible, at every width

- **+** (attach and the plus menu).
- **The access glyph** (the permission mode's icon; only its label goes).
- **The mic**, and a listening mic's waveform. Codex's speed bolt beside it.
- **Send or Stop.**
- **Every chevron**: a control that opens a menu always shows it opens one.
- **The hat's counts and phase words** while anything runs (below). The hat never shows the exact
  call.

When the room runs out, the prompt gives way, never one of these. A control without its name keeps
its icon, its tooltip and its accessible name.

## The hat: what it says

From [composer-hat-calm.md](composer-hat-calm.md), the default (`phase` arm):

- A line says what a subagent is doing as a **phase word** of fixed width ("Thinking", "Reading",
  "Editing", "Running", "Delegating"), never the call's own text.
- A word holds at least **1.6 s** (`PHASE_DWELL_MS`). Bursts become one change, not one per call.
- **Counts** ("3 subagents running · 2 commands") change only when an item starts or ends, and only
  their changed digits roll.
- **Elapsed time** ticks once a second in tabular figures.
- **Tokens and call counts never appear in the hat.** The opened line's details and Session Info show
  them.
- **0 running: no hat.** 1 running: one line. Many: the newest names and "+N more", held 1.6 s.

## Glass and shape

From [glass-system.md](glass-system.md):

- The composer box is the **one hero glass surface**: `.ui-glass .ui-glass-floats .ui-glass-material`
  (`ComposerBox.tsx`). It is the only surface with the specular sheen.
- **One edge.** The `--acpmux-composer-edge` hairline (one device pixel, clear under
  `appearance.borders = none`), plus the glass's lit top hairline. No second border.
- **Shadow** `--elevation-1` in a light theme, none in a dark one. Focus is quiet
  (`composerStates.css`).
- The location strip, the queue and the hat **continue the card's surface**. They are never a second
  box over the wallpaper.
- **Radius** is one token, `--cmux-composer-radius`. The hat takes `--cmux-composer-hat-radius`,
  falling back to the composer's. No lane sets a radius literal on the composer or the hat.
- Menus and popovers that open from the composer (pickers, the environment picker) are floating web
  glass at the menu level. Never glass on glass: a menu over the composer lays its own tint, the
  composer does not blur under it, and there are at most two backdrop-filtered surfaces on screen
  (glass rule 7).
- Reduce Transparency and Liquid Glass off draw the opaque surface and its hairline.

## iOS

The iOS composer follows the same order of priorities in points:

- What shortens first: effort, then the model, then the permission label.
- What never leaves: +, mic, Send or Stop.
- The hat's phase words and dwell are the same.

It differs only where the platform does: the system keyboard, swipe gestures, and the height cap.

## The done check for a composer change

A composer change is done when its screenshots show the composer at **260, 320 and 400 px** (and a
wide reference), with **0, 1 and 5** things running in the hat, and nothing is cut, overlapping or
missing from the always-visible list. Take them from the gallery (`bun run compare:agent-pane` or the
gallery dev server) in CI, then from a side copy of NIGHTLY (`scripts/cmux-next/side-instance.sh`),
never Leo's own app.

## Never

- A label cut mid-word in the controls row.
- A control from the always-visible list hidden to make room.
- The exact tool call, a token count or a per-call counter in the hat.
- A width step in a lane's own CSS instead of `COMPOSER_FIT_STEPS`.
- A radius or glass tint literal on the composer or the hat.
- A second border, or glass on glass.
