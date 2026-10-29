// l10n-allow-file: transcript geometry fixtures.
import { expect, test } from "bun:test";
import { layoutConversation, placeRows, type AcpmuxRow, type RowHeights } from "./model";
import { TRANSCRIPT_BLOCK_GAP, TRANSCRIPT_TURN_GAP } from "./transcriptGrid";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 0,
  ...fields,
});
const answer = row("answer", "assistant", { text: "Done." });
const footer = row("footer", "turnSummary", { text: "Done.", durationMs: 1000, status: "completed" });
const hidden = row("hidden", "user", { incoming: { kind: "hidden" } });

test("container gaps cross hover footers and bookkeeping without adding a second gap", () => {
  for (const next of [
    row("reply", "assistant", { text: "Next." }),
    row("prompt", "user", { text: "Next." }),
    row("peer", "user", { incoming: { kind: "message", message: { name: "peer", text: "Report", raw: "Report" } } }),
  ]) {
    const rows = [answer, footer, hidden, next];
    const layout = layoutConversation(rows, 720);
    expect(layout.heights[1]).toBe(0);
    expect(layout.heights[2]).toBe(0);
    const gap = next.id === "prompt" ? TRANSCRIPT_TURN_GAP : TRANSCRIPT_BLOCK_GAP;
    expect(layout.tops[3]! - layout.heights[0]!).toBe(gap);
    const measured = placeRows(layout, (index) => (index === 0 ? 100 : undefined));
    expect(measured.tops[3]).toBe(100 + gap);
  }
});

test("incremental placement matches fresh placement when a continuation becomes a prompt", () => {
  const known: RowHeights = new WeakMap();
  const rows = [answer, footer, hidden];
  const layout = layoutConversation(rows, 720, undefined, undefined, known);
  const next = [...rows, row("next", "assistant", { text: "Next update." })];
  const continued = layoutConversation(next, 720, undefined, undefined, known, { rows, layout });
  expect(continued).toEqual(layoutConversation(next, 720));
  const changed = [...rows, row("next", "user", { text: "Next task." })];
  expect(layoutConversation(changed, 720, undefined, undefined, known, { rows: next, layout: continued })).toEqual(
    layoutConversation(changed, 720),
  );
});

test("failure and Continue controls remain content; completed footer copy is an overlay", () => {
  expect(layoutConversation([footer], 720).totalHeight).toBe(0);
  for (const fields of [{ status: "failed", error: "Retry" }, { resumable: true }])
    expect(layoutConversation([{ ...footer, ...fields }], 720).heights[0]).toBeGreaterThan(0);
});

test("measured empty rows do not leave a gap at the beginning or the end", () => {
  const rows = [hidden, answer, footer];
  const estimate = layoutConversation(rows, 720);
  const measured = placeRows(estimate, (index) => (index === 1 ? 40 : 0));
  expect([...measured.tops]).toEqual([0, 0, 40]);
  expect(measured.totalHeight).toBe(40);
});
