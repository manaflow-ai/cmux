// l10n-allow-file: test fixture text, not shipped UI.
// A stretch the agent ran on its own that ended with its footer while the chat still works: the live
// line takes that footer's slot, and the footer comes back in it once the work ends, so the end moves
// nothing (Leo, 2026-11-08: "the bottom buttons appear and then there's thinking then thinking
// disappears then there's a jolt. but the thinking should essentially take the same spot as the
// bottom buttons i think?"). Before: the line stood a 32 row under the footer and the chat's bottom
// rose by it when the work ended.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../model";
import { MARK_FOOTER_ROW, MARK_FOOTER_SLOT } from "../transcriptGrid";
import { turnView } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const prompted = [
  row("prompt", "user", 0, { text: "Watch the deploy" }),
  row("reply", "assistant", 1_000, { text: "Watching it." }),
  row("summary", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
];
const background = { id: "b1", trigger: "task", running: false, quiet: false, hasRows: true as const };
const tails: Record<string, AcpmuxRow[]> = {
  // acpmux ends a Claude turn the agent ran on its own with its background_turn ended record.
  "a background turn's reply": [
    row("backgroundTurn-b1", "backgroundTurn", 30_000, { background }),
    row("woken", "assistant", 31_000, { text: "The deploy finished.", inBackground: "b1" }),
  ],
  // A self-started turn acpmux ended with its own turn result, after a call.
  "a self-started turn's summary": [
    row("call", "activity", 30_000, {
      items: [
        {
          kind: "tool",
          text: "ls",
          tool: { id: "t1", kind: "execute", title: "ls", command: "ls", status: "completed" },
        },
      ],
    }),
    row("woken", "assistant", 31_000, { text: "Listed." }),
    row("woken-end", "turnSummary", 32_000, { status: "completed", durationMs: 2_000, turnId: "woken-turn" }),
  ],
};

const bottom = (rows: AcpmuxRow[]) => {
  const layout = layoutConversation(rows, 720);
  return { layout, end: layout.totalHeight + (layout.tailGap ?? 0) + (layout.restBand ?? 0) };
};

for (const [name, tail] of Object.entries(tails))
  test(`${name}: the live line holds its footer's slot, and the footer comes back in it`, () => {
    const options = { now: 60_000, agentFamily: "claude" };
    const live = turnView([...prompted, ...tail], new Set(), { ...options, working: true });
    const done = turnView([...prompted, ...tail], new Set(), { ...options, working: false });
    const during = bottom(live);
    const after = bottom(done);
    // While it works, the line is the last row and the footer under the reply is not drawn too.
    expect(live.at(-1)!.below).toBe(true);
    expect(live.at(-2)!.kind).not.toBe("turnSummary");
    expect(during.layout.marks![live.length - 1]).toBe(MARK_FOOTER_SLOT);
    // Once it ends, the footer is the last row, in the line's place.
    expect(done.at(-1)!.kind).toBe("turnSummary");
    expect(after.layout.marks![done.length - 1]).toBe(MARK_FOOTER_ROW);
    expect(after.layout.tops[done.length - 1]).toBe(during.layout.tops[live.length - 1]);
    expect(after.end).toBe(during.end);
  });
