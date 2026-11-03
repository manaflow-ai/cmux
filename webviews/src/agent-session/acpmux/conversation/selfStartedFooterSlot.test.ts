// l10n-allow-file: test fixture text, not shipped UI.
// A turn the agent started on its own after the prompt's turn ended (no prompt opens it) is a turn
// like any other at its end: while its reply streams, the live line holds the footer's slot under it,
// and when it ends its footer is the reply's 32 row in that slot, so the end moves nothing
// (design/transcript-spacing.md "Reply footer", chat-transcript.md "A turn that ends moves nothing").
// Before: the self-started turn had no live line and ended in an empty footer laid over the gap, so
// its end pushed the composer 26 down (restBand), and its reply had no Copy footer.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../model";
import { MARK_FOOTER_ROW, MARK_FOOTER_SLOT, TRANSCRIPT_FOOTER_CONTROL, TRANSCRIPT_FOOTER_GAP } from "../transcriptGrid";
import { turnView } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const options = { now: 60_000, liveRuns: true, lineBelow: true };
const prompted = [
  row("prompt", "user", 0, { text: "Watch the deploy" }),
  row("reply", "assistant", 1_000, { text: "Watching it." }),
  row("summary", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
];
const streamed = row("woken", "assistant", 30_000, { text: "The deploy finished: every check is green." });
const ended = row("woken-end", "turnSummary", 40_000, { status: "completed", durationMs: 10_000 });

/// Where the bottom of the transcript is: its last drawn row's end plus the gap to the composer.
const bottom = (rows: AcpmuxRow[]) => {
  const layout = layoutConversation(rows, 720);
  return { layout, end: layout.totalHeight + (layout.tailGap ?? 0) + (layout.restBand ?? 0) };
};

for (const agentFamily of ["claude", "codex"])
  test(`${agentFamily}: a reply in a turn the agent started on its own ends in place, its footer in the live line's slot`, () => {
    const live = turnView([...prompted, streamed], new Set(), { ...options, agentFamily, working: true });
    const done = turnView([...prompted, streamed, ended], new Set(), { ...options, agentFamily, working: false });
    const during = bottom(live);
    const after = bottom(done);
    // While it streams, the live line holds the footer's slot 8 under the reply.
    const slot = live.findIndex((entry) => entry.below);
    expect(slot).toBe(live.length - 1);
    expect(during.layout.marks![slot]).toBe(MARK_FOOTER_SLOT);
    // Once it ends, the reply's footer is a row of its own in that slot, with the reply to copy.
    const footer = done.at(-1)!;
    expect(footer).toMatchObject({ kind: "turnSummary", text: streamed.text });
    expect(after.layout.marks![done.length - 1]).toBe(MARK_FOOTER_ROW);
    const reply = done.findIndex((entry) => entry.id === streamed.id);
    expect(after.layout.tops[done.length - 1]! - (after.layout.tops[reply]! + after.layout.heights[reply]!)).toBe(
      TRANSCRIPT_FOOTER_GAP,
    );
    expect(after.layout.heights[done.length - 1]).toBe(TRANSCRIPT_FOOTER_CONTROL);
    // Nothing moved: the reply's place, the slot's and the composer's.
    expect(after.layout.tops[reply]).toBe(during.layout.tops[live.findIndex((entry) => entry.id === streamed.id)]);
    expect(after.layout.tops[done.length - 1]).toBe(during.layout.tops[slot]);
    expect(after.end).toBe(during.end);
  });
