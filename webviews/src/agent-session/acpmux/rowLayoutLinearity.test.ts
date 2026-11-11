// l10n-allow-file: geometry fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow, type RowHeights } from "./model";

const row = (id: string, kind: string): AcpmuxRow => ({ id, version: 1, at: 0, kind });

test("bookkeeping runs are visited linearly when placing a transcript", () => {
  let visits = 0;
  const hidden = Array.from({ length: 2_048 }, (_, i): AcpmuxRow => ({
    ...row(`h${i}`, "user"),
    get incoming(): AcpmuxRow["incoming"] {
      visits += 1;
      return { kind: "hidden" };
    },
  }));
  const answer = { ...row("answer", "assistant"), text: "Done." };
  const footer = row("footer", "turnSummary");
  const rows = [answer, ...hidden, footer];
  const known: RowHeights = new WeakMap();
  const layout = layoutConversation(rows, 720, undefined, undefined, known);
  expect(layout.totalHeight).toBe(layout.heights[0]! + layout.heights.at(-1)!);
  expect(layout.tops.at(-1)).toBe(layout.heights[0]);
  expect(layout.heights.slice(1, -1).every((height) => height === 0)).toBe(true);
  expect(layout.heights[0]).toBe(layoutConversation([answer, footer], 720).heights[0]);
  expect(visits).toBeLessThan(rows.length * 12);

  // A changed leading row invalidates placement, even with every old height cached.
  visits = 0;
  const next = [{ ...answer, version: 2 }, ...hidden, footer];
  const updated = layoutConversation(next, 720, undefined, undefined, known, { rows, layout });
  expect(updated.tops).toEqual(layout.tops);
  expect(updated.heights).toEqual(layout.heights);
  expect(visits).toBeLessThan(rows.length * 12);
});

test("appending a footer past bookkeeping updates the retained reply edge", () => {
  const answer = { ...row("answer", "assistant"), text: "Done." };
  const hidden = Array.from({ length: 100 }, (_, i): AcpmuxRow => ({
    ...row(`h${i}`, "user"),
    incoming: { kind: "hidden" },
  }));
  const rows = [answer, ...hidden];
  const known: RowHeights = new WeakMap();
  const layout = layoutConversation(rows, 720, undefined, undefined, known);
  const next = [...rows, row("footer", "turnSummary")];
  const updated = layoutConversation(next, 720, undefined, undefined, known, { rows, layout });
  const fresh = layoutConversation(next, 720);
  expect(updated).toEqual(fresh);
  expect(updated.heights[0]).toBe(layout.heights[0]!);
  // Removing it must restore the retained reply's original gap as well.
  expect(layoutConversation(rows, 720, undefined, undefined, known, { rows: next, layout: updated })).toEqual(layout);
});

// One row per record is the worst case for record-to-row compaction. Keep this
// model-only measurement separate from browser/frame claims: there is no DOM here.
test("a 192k-record-shaped transcript keeps its tail geometry on steady updates", () => {
  const count = 192_000;
  let rows: AcpmuxRow[] = Array.from({ length: count }, (_, i) => ({
    ...row(`r${i}`, i % 24_000 === 0 ? "notice" : "user"),
    ...(i % 24_000 === 0 ? {} : { incoming: { kind: "hidden" as const } }),
  }));
  const known: RowHeights = new WeakMap();
  const start = performance.now();
  let layout = layoutConversation(rows, 720, undefined, undefined, known);
  const cold = performance.now() - start;
  const total = layout.totalHeight;
  const samples: number[] = [];
  for (let revision = 2; revision < 34; revision += 1) {
    const next = rows.slice();
    next[count - 1] = { ...rows[count - 1]!, version: revision };
    const at = performance.now();
    const updated = layoutConversation(next, 720, undefined, undefined, known, { rows, layout });
    samples.push(performance.now() - at);
    expect(updated.totalHeight).toBe(total);
    expect(updated.tops.at(-1)).toBe(total);
    rows = next;
    layout = updated;
  }
  samples.sort((a, b) => a - b);
  console.info("192k row layout ms", {
    cold,
    p50: samples[15],
    p95: samples[30],
    p99: samples[31],
    max: samples[31],
  });
}, 30_000);

// A divider drag (Leo, 2026-11-11: "the dragging responsiveness is slow for agent chat but fast for
// browser hmmm"): each frame at a new width measures only the rows around the view, so a frame's cost
// does not grow with the chat; the rows out of view keep the last width's heights until it settles.
test("a live resize frame measures only the rows around the view", () => {
  const rows: AcpmuxRow[] = Array.from({ length: 600 }, (_, i) => ({
    ...row(`r${i}`, i % 2 === 0 ? "user" : "assistant"),
    text: `Message ${i}: ${"a few words that wrap at a narrow width ".repeat(1 + (i % 5))}`,
  }));
  const wide = layoutConversation(rows, 900);
  let measured = 0;
  const counting = (width: number) =>
    layoutConversation(
      rows,
      width,
      undefined,
      () => {
        measured += 1;
        return undefined;
      },
      undefined,
      undefined,
      undefined,
      { rows, layout: wide, from: 560, to: 600 },
    );
  const narrow = counting(500);
  expect(measured).toBe(40);
  // Out of view: the last width's heights; in view: this width's, as a full layout has them.
  const full = layoutConversation(rows, 500);
  expect(narrow.heights.slice(0, 560)).toEqual(wide.heights.slice(0, 560));
  expect(narrow.heights.slice(560)).toEqual(full.heights.slice(560));
  expect(full.heights.slice(560)).not.toEqual(wide.heights.slice(560));
  // A row that changed during the drag (a streamed reply) is measured wherever it is.
  measured = 0;
  const changed = [...rows];
  changed[3] = { ...rows[3]!, version: 2, text: "Changed." };
  layoutConversation(
    changed,
    500,
    undefined,
    () => {
      measured += 1;
      return undefined;
    },
    undefined,
    undefined,
    undefined,
    { rows, layout: wide, from: 560, to: 600 },
  );
  expect(measured).toBe(41);
});
