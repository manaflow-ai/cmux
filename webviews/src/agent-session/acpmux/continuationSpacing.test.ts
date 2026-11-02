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

// Review at 1691838: a placement kept from 100% must not survive a change to 125% Interface Size,
// or its rows keep the 100% gaps while the CSS tokens draw the 125% ones.
test("placed gaps follow an Interface Size change, kept rows included", () => {
  const g = globalThis as { document?: unknown; getComputedStyle?: unknown };
  const saved = { document: g.document, getComputedStyle: g.getComputedStyle };
  let scale = "1";
  g.document ??= { documentElement: {} };
  g.getComputedStyle = () => ({ getPropertyValue: (name: string) => (name === "--cmux-interface-scale" ? scale : "") });
  try {
    const rows = [
      { id: "a", version: 1, at: 0, kind: "assistant", text: "One." },
      { id: "b", version: 1, at: 1, kind: "assistant", text: "Two." },
    ] as AcpmuxRow[];
    const heightAt = () => 20;
    const estimate = layoutConversation(rows, 720);
    const atOne = placeRows(estimate, heightAt);
    expect(atOne.tops[1]! - atOne.tops[0]!).toBe(20 + 24);
    scale = "1.25";
    const atLarger = placeRows(estimate, heightAt, { layout: atOne, kept: 2 });
    expect(atLarger.tops[1]! - atLarger.tops[0]!).toBe(20 + 30);
    expect(atLarger.scale).toBe(1.25);
    const relaid = layoutConversation(rows, 720, undefined, undefined, undefined, { rows, layout: estimate });
    expect(relaid.scale).toBe(1.25);
    expect(relaid.gaps?.[1]).toBe(30);
  } finally {
    g.document = saved.document;
    g.getComputedStyle = saved.getComputedStyle;
  }
});

// Review at b1de39a: row estimates built from grid lengths (the action row, a tool row) scale with
// the Interface Size like the CSS tokens, so first placement does not jump when rows are measured.
test("estimated grid rows follow the Interface Size", () => {
  const g = globalThis as { document?: unknown; getComputedStyle?: unknown };
  const saved = { document: g.document, getComputedStyle: g.getComputedStyle };
  let scale = "1";
  g.document ??= { documentElement: {} };
  g.getComputedStyle = () => ({ getPropertyValue: (name: string) => (name === "--cmux-interface-scale" ? scale : "") });
  try {
    const received = [
      { id: "r", version: 1, at: 0, kind: "user", text: "Task", received: {} },
    ] as unknown as AcpmuxRow[];
    // Two shell calls: two tool rows and the block gap between them, all grid lengths.
    const run = [
      {
        id: "run",
        version: 1,
        at: 0,
        kind: "activity",
        items: [
          { id: "one", tool: { kind: "execute", title: "ls" } },
          { id: "two", tool: { kind: "execute", title: "pwd" } },
        ],
      },
    ] as unknown as AcpmuxRow[];
    for (const rows of [received, run]) {
      scale = "1";
      const atOne = layoutConversation(rows, 720).heights[0]!;
      scale = "1.25";
      const atLarger = layoutConversation(rows, 720).heights[0]!;
      expect(atOne).toBeGreaterThan(0);
      expect(atLarger).toBeCloseTo(atOne * 1.25, 5);
    }
  } finally {
    g.document = saved.document;
    g.getComputedStyle = saved.getComputedStyle;
  }
});
