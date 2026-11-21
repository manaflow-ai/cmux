# Chat row rhythm

One owner: `transcriptGap(previous, next)` in `src/agent-session/acpmux/transcriptGrid.ts`. Row CSS carries no padding or
margin, so the first layout (`layoutConversation`) and the drawn rows agree and nothing jumps.

## Rule

- One-line rows (a step, a status line, a group's head, a group's children, a background turn's lines) sit flush on the
  22 pitch: gap 0, whichever turn made them. A background turn opening under a one-line row does not add the turn gap.
- "Worked for" stands the run gap (16) over a one-line row above it; it keeps its own 4 under the words and 8 under the
  rule, and nothing after it.
- Prose, a prompt and a footer keep their gaps: 8 under a reply (its footer), 16 between a run and prose, 24 between
  blocks, 32 around a prompt or a turn that opens under prose or a footer.

## Why

Leo, 2026-11-21: "the spacing is just insanely shit here. way too close." and, on an opened "Sent 3 messages" group, uneven
blank bands above its first child and between children. Measured before: any line to a background turn's line was 32;
"Worked for" under a line was 0.

## Table

`src/agent-session/acpmux/rowGapTable.test.ts` holds the 11x11 table of adjacent kinds (model level, deterministic).
`test/chat-row-spacing.test.ts` measures the drawn rows in Chromium with getBoundingClientRect.

## Variants

Gallery `agent-pane.chat-row-spacing`, `<html data-row-gap>`: `before`, `tight` ("Worked for" 8), `shipped` (16),
`roomy` (24), each closed and opened. Sheets: round 1 (opened), round 2 (closed), light and dark. Pick: `shipped` -
8 reads as the footer's gap, 24 detaches the header from the run it summarizes and stands taller than the 16 the prose
below it keeps from a run.
