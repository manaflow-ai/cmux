# Composer send slot: its states and their morphs

Leo, 2026-11-22: “transitions from send to stop to start to whatever need better morphing, maybe.
it's ok now but maybe it could be better? we can hill climb that too. idle to send to stop to
whatever we need those to be like... known. anyways, unsending a message that didnt already get
sent should have proper animations too, i think. an "un-pop"?”

The composer's one action button (the send slot) is a known state machine. The spec is code:
`webviews/src/agent-session/acpmux/composer/sendSlotTransitions.ts` holds three tables, and
`SendSlotGlyph.tsx` reads them at run time to choose each morph. Change the tables, not this page;
this page states the rules the tables keep.

## States

| State | Claude's look | Codex's look | When |
| --- | --- | --- | --- |
| idle | nothing | ↑ dimmed | empty draft, no turn |
| send-ready | ↵ | ↑ accent | a draft (text, attachments, dictation) |
| sending | nothing | ↑ dimmed | Return pressed, the host has not taken the prompt |
| stop | ■ | ■ | a turn runs and the draft is empty |
| stopping | ring | ring | Stop sent, the turn not yet ended |
| queued | ▶ | ▶ | the queue is paused (Resume) |
| unsend | ↵ | ↑ | a queued prompt pulled back before it was sent |

A prompt held behind a running turn keeps `stop` (turnHandover.ts). One held behind the folder's
trust question keeps its draft's glyph, disabled; only its ink changes.

## Rules

- Every ordered pair of drawn glyphs has a row: a morph with its duration token, easing token and
  Reduce Motion behaviour, or `none` (same glyph) or `instant` with its reason.
- Every ordered pair of states says whether it can happen. A reachable pair resolves to a row in
  both looks.
- Every morph runs once on the motion scale's standard step (180 ms, `--agent-motion-move`) with
  `--cmux-ease-out`. Under Reduce Motion, motion off or a hidden page, the new glyph is drawn in one
  frame with no copy.
- The button's 28 px box never moves or resizes. The old and new glyphs share its one grid cell.
- One glyph change runs one morph, never two.
- A glyph whose button leaves the bar (Claude's look emptying) is `instant`, because nothing is
  left to draw a copy in.
- Nothing morphs on the first draw, or within 300 ms (`SETTLE_MS`) of a chat switch or read.
- Claude's Stop grows in (`enter`) from an empty slot, the send's own Stop and a turn started
  elsewhere alike: it shows only once the turn held (turnPresence.ts, #51225), so its arrival is a
  real change. A Stop that left and comes back is drawn at once.
- A change of state that keeps its glyph and its button keeps its glyph. In Codex's look,
  `send-ready` to `sending` changes only the ink.
- Changes into and out of `unsend` that change the glyph, with a button still drawn, run `unpop`.
  The composer-unpop lane owns its keyframes through `[data-send-unpop]`. Until they land, `unpop`
  draws the scale layers.

## Shipped morphs

| From → to | Morph |
| --- | --- |
| ↵ / ↑ → ■ or ring (a turn starts) | crossfade, standard, ease-out |
| ■ or ring → ↵ / ↑ (a turn ends, a letter typed mid-turn) | crossfade |
| ■ → ring (Stop pressed), ring → ■ | crossfade |
| ↵ / ↑ ↔ ▶ (queue paused, letter typed) | crossfade |
| ▶ → ■ (Resume) | crossfade |
| nothing → ■ within GAP_MS (the send's Stop, Claude's look) | enter |
| nothing → ↵ / ▶, anything → nothing | instant |
| ↵ ↔ ↑ (look switch) | instant |
| into or out of unsend, glyph changes | unpop |

The crossfade's style is experiment `send-stop-morph` (scale by default; rotate, path, blur).

## Detector

`send-slot-transitions-complete`:

- `webviews/src/agent-session/acpmux/composer/sendSlotTransitions.test.ts` (bun test, no
  browser) fails when a glyph or a state lacks its rows, or when a reachable pair resolves to no
  morph. It also fails when a row's tokens leave the motion scale, or when `morphFrom` stops doing
  what the table says. It checks every gallery morph set too.
- `webviews/test/send-slot-states.browser.test.ts` plays idle → send-ready → sending → stop →
  stopping → idle in every variant of gallery `agent-pane.composer-send-slot-states`, reading
  every frame. It fails when the box moves or resizes, or when a glyph change runs a different
  number of morphs than the table names.

## Candidates (gallery, not shipped)

`agent-pane.composer-send-slot-states` has one variant per whole morph set
(`sendSlotVariants.ts`): `scale` (shipped), `path-send-stop`, `sending-ring` and
`enter-on-type`. The coordinator chooses; none flips a default.
