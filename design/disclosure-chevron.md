# The chevron after a label

Every control that shows words and then a disclosure chevron (a menu trigger, a picker chip, a
transcript row's fold, a sender's chip with its row chevron) keeps the same room between the two.
Leo, 2026-11-27, on a received message's sender chip ("acpmux⌄") and a sender's machine
("· host⌄") whose chevrons touched their last letter: "these chevrons are too close dont we have
any guidelines for these yet?". There was none: this page is it.

## The rule

| What | Value | Where |
|---|---|---|
| Room from the last visible letter's edge to the chevron's ink | 4–8 px; 5–7 px in a shipped control | measured, below |
| Box gap before the chevron (a control's own words and chevron) | `--ui-disclosure-gap`, one spacing step: `--ds-space-1` (4 px) | `webviews/src/ui/ghost.css` `.ui-disclosure-face` |
| The chevron | the icon registry's `disclosure.expanded` (or the transcript's turned `ChevronRight`), a 12 px box, never a font glyph | `DisclosureFace.tsx` `DisclosureChevron`, `conversation.css` `--cv-chevron-glyph` |
| Transcript rows | `--cv-chevron-gap` (5 px) from the words' edge to the ink | `conversation.css` |
| Truncation | the label ellipsizes first (`min-width: 0`, `text-overflow: ellipsis`); the chevron is `flex: none`, never cut, never drawn over the words | `.ui-disclosure-face__label` |

- **Draw it with the shared pair.** A new control writes
  `<DisclosureFace>{label}</DisclosureFace>` (`webviews/src/agent-session/acpmux/DisclosureFace.tsx`),
  or `<DisclosureChevron />` after words it lays out itself, and does not set its own margin, gap or
  negative pull on the chevron. A control whose words and chevron sit in different boxes (a
  transcript row's toggle after the sender's chip) keeps the same room with its own rule, and the
  test measures it.
- **Never a text "⌄".** A font's chevron glyph sits on the baseline with whatever side bearing
  the fallback font gives it, so the room changes per font and per machine.
  `check:disclosure-chevron` fails a TSX file that draws one.
- **No pull-backs onto the words.** A negative margin that moves a chevron toward its label must
  stop where the room above begins; a chip's end padding is not room after a bare word that may
  follow it (a machine name after the chip).

Why one spacing step: the gallery `ui.disclosure-face` compares 2, 4 and 8 px box gaps on the two
chips Leo flagged and on a label cut at 120 px. At 2 px the chevron reads as a letter; at 8 px it
floats off its label; 4 px gives about the same visible room as the transcript's chevrons, which
Leo picked as ChatGPT's ("this how chatgpt does their chevrons", 2026-11-03).

## How it is checked

- `webviews/test/disclosure-chevron-gap.test.ts` opens gallery scenes in Chromium and measures every
  label + chevron pair (`test/support/disclosureChevrons.ts`): the ink starts 3–10 px after the last
  visible words and is never cut by a clipping box.
- `webviews/test/transcript-chevron-after-label.test.ts` keeps each transcript chevron 3–8 px after
  its words (before 2026-11-27 it had only the upper bound, so a chevron on the words passed).
- `scripts/check-disclosure-chevron.mjs` (`bun run check:disclosure-chevron`): no text "⌄" chevron
  in shipped TSX.
