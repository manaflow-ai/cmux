// l10n-allow-file: geometry fixtures, not shipped UI.
// A transcript's layout keeps its arrays from one estimate to the next (model.ts LayoutBuffers): a
// streamed token writes the rows it changed and allocates nothing by the chat's row count, and
// every layout reads exactly what a layout into new arrays reads (chat-instant-under-load.md piece 4).
import { expect, test } from "bun:test";
import { LayoutBuffers, layoutConversation, type AcpmuxRow, type ConversationLayout, type RowHeights } from "./model";

const at = 1_700_000_000_000;
const prompt = (index: number): AcpmuxRow => ({
  id: `u${index}`,
  version: 1,
  at,
  kind: "user",
  text: `Prompt ${index}`,
});
const reply = (index: number, text: string, version = 1): AcpmuxRow => ({
  id: `a${index}`,
  version,
  at,
  kind: "assistant",
  text,
});
const footer = (index: number): AcpmuxRow => ({ id: `f${index}`, version: 1, at, kind: "turnSummary" });

const arrays = (layout: ConversationLayout) => ({
  tops: [...layout.tops],
  heights: [...layout.heights],
  gaps: [...(layout.gaps ?? [])],
  marks: [...(layout.marks ?? [])],
  totalHeight: layout.totalHeight,
  tailGap: layout.tailGap,
  restBand: layout.restBand,
});

test("a layout into kept arrays reads what a layout into new arrays reads, update after update", () => {
  const buffers = new LayoutBuffers();
  const knownKept: RowHeights = new WeakMap();
  const knownFresh: RowHeights = new WeakMap();
  let rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < 40; turn += 1)
    rows.push(prompt(turn), reply(turn, `Answer ${turn}. `.repeat((turn % 7) + 1)), footer(turn));
  let kept: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  let fresh: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  const step = (next: AcpmuxRow[]) => {
    const a = layoutConversation(
      next,
      720,
      undefined,
      undefined,
      knownKept,
      kept,
      "s",
      undefined,
      undefined,
      undefined,
      buffers,
    );
    const b = layoutConversation(next, 720, undefined, undefined, knownFresh, fresh, "s");
    expect(arrays(a)).toEqual(arrays(b));
    // The layout before keeps its own values: the next one writes into another set.
    if (kept) expect(arrays(kept.layout)).toEqual(arrays(fresh!.layout));
    kept = { rows: next, layout: a };
    fresh = { rows: next, layout: b };
    rows = next;
  };
  step(rows);
  // A reply streams: each token a new last row.
  rows.push(prompt(40));
  step([...rows]);
  let text = "";
  for (let token = 0; token < 30; token += 1) {
    text += `word${token} `;
    step([...rows.slice(0, rows.length - (token ? 1 : 0)), reply(40, text, token + 1)]);
  }
  step([...rows, footer(40)]);
  // A row in the middle changes, rows are removed, a page of older rows lands in front.
  step(rows.map((row, index) => (index === 10 ? { ...row, version: 2, text: "Edited." } : row)));
  step(rows.slice(0, 50));
  step([prompt(-2), reply(-2, "Older."), footer(-2), ...rows]);
  // Another chat (no layout to keep), then streaming again.
  kept = undefined;
  fresh = undefined;
  step([prompt(0), reply(0, "Fresh chat.")]);
  for (let token = 0; token < 6; token += 1)
    step([prompt(0), reply(0, `Fresh chat ${"more ".repeat(token)}`, token + 2)]);
});

test("a streamed token writes into kept arrays: none sized by the chat's rows is allocated", () => {
  const buffers = new LayoutBuffers();
  const known: RowHeights = new WeakMap();
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < 2_000; turn += 1) rows.push(prompt(turn), footer(turn));
  let last = {
    rows: rows as readonly AcpmuxRow[],
    layout: layoutConversation(
      rows,
      720,
      undefined,
      undefined,
      known,
      undefined,
      "s",
      undefined,
      undefined,
      undefined,
      buffers,
    ),
  };
  const seen = new Set<ArrayBufferLike>();
  for (let token = 0; token < 30; token += 1) {
    const next = [...rows, reply(9_999, `${"word ".repeat(token + 1)}`, token + 1)];
    const layout = layoutConversation(
      next,
      720,
      undefined,
      undefined,
      known,
      last,
      "s",
      undefined,
      undefined,
      undefined,
      buffers,
    );
    seen.add(layout.tops.buffer);
    last = { rows: next, layout };
  }
  // Three sets take turns; growing past the first capacity may add one more each.
  expect(seen.size).toBeLessThanOrEqual(6);
});

test("a layout the transcript still holds keeps its values however many estimates come after it", () => {
  // The last committed placement (VirtualTranscript previousLayout) reads its estimate's arrays
  // (placedFromEstimate keeps gaps and marks and reads tops and heights). Several estimates can come
  // before the next commit (a send during a running call: the prompt, the queue, a token), so a set
  // a held layout reads is never written over.
  const buffers = new LayoutBuffers();
  const known: RowHeights = new WeakMap();
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < 20; turn += 1) rows.push(prompt(turn), reply(turn, `Answer ${turn}.`), footer(turn));
  let last = {
    rows: rows as readonly AcpmuxRow[],
    layout: layoutConversation(
      rows,
      720,
      undefined,
      undefined,
      known,
      undefined,
      "s",
      undefined,
      undefined,
      undefined,
      buffers,
    ),
  };
  const held = last.layout;
  const values = arrays(held);
  buffers.hold(held);
  for (let token = 0; token < 8; token += 1) {
    // A reply above the held rows' end grows (a tool call's output streaming in), so every row
    // below it moves.
    const next = rows.map((row, index) =>
      index === 4 ? reply(1, `${"word ".repeat((token + 1) * 40)}`, token + 2) : row,
    );
    const layout = layoutConversation(
      next,
      720,
      undefined,
      undefined,
      known,
      last,
      "s",
      undefined,
      undefined,
      undefined,
      buffers,
    );
    last = { rows: next, layout };
  }
  expect(arrays(held)).toEqual(values);
});
