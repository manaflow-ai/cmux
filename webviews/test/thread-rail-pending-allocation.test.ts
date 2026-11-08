import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { RailRows, tickRows, turnRows, pendingTurn } from "../src/agent-session/acpmux/threadMinimap/railRows";
import { tickRanges } from "../src/agent-session/acpmux/threadMinimap/tickWindow";

const held = (count: number): AcpmuxRow[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `user-${10000 - count + index}`,
    kind: "user",
    text: `Question ${index}`,
    version: 1,
    at: 1,
  }));

test("10,000 count-only turns allocate only the twelve held turns and ticks", () => {
  const read = minimapTurns(held(12), "allocation", undefined, undefined, [], 10000);
  // These are the actual model objects retained before the rail renders, not DOM nodes.
  const objects = new Set([...read.turns, ...read.ticks]);
  console.log(`rail model objects at 10000 turns: ${objects.size}`);
  expect(objects.size).toBe(24);
  expect(read.pendingCount).toBe(9988);
  const turns = turnRows(read.turns, read.pendingCount!, "allocation");
  const ticks = tickRows(read.ticks, read.pendingCount!, "allocation");
  expect(turns.length).toBe(10000);
  expect(ticks.length).toBe(10000);
  expect(turns.at(9987)?.pending).toBe(true);
  expect(turns.at(9988)?.id).toBe(read.turns[0]!.id);
  expect(turns.at(-1)).toBe(read.turns.at(-1));
});

test("placeholder allocations follow the visible window, not the historical count", () => {
  const allocations = (count: number) => {
    let objects = 0;
    const rows = new RailRows([], count, "window", (session, index) => {
      objects += 1;
      return pendingTurn(session, index);
    });
    expect(rows.length).toBe(count);
    expect(rows.keyIndex(`window#pending:${count - 1}`)).toBe(count - 1);
    expect(rows.keyIndex("another#pending:1")).toBeUndefined();
    expect(rows.keyIndex(`window#pending:${count}`)).toBeUndefined();
    expect(objects).toBe(0);
    for (const [from, to] of tickRanges(rows.length, 0, 500, []))
      for (let index = from; index < to; index++) expect(rows.at(index)?.id).toBe(`pending:${index}`);
    return objects;
  };
  const small = allocations(100);
  expect(allocations(10000)).toBe(small);
  expect(small).toBeLessThan(100);
});

test("history replaces the pending prefix in place and streaming keeps ticks", () => {
  const rows = held(12);
  const initial = minimapTurns(rows, "pages", undefined, undefined, [], 10000);
  const older = held(24);
  const page = minimapTurns(older, "pages", initial, undefined, [], 10000);
  const initialRows = tickRows(initial.ticks, initial.pendingCount!, "pages");
  const pageRows = tickRows(page.ticks, page.pendingCount!, "pages");
  expect(pageRows.length).toBe(initialRows.length);
  for (const tick of initial.ticks) expect(pageRows.keyIndex(tick.key)).toBe(initialRows.keyIndex(tick.key));
  const reply: AcpmuxRow = { id: "reply", kind: "assistant", text: "A reply", at: 1, version: 1 };
  const streamed = minimapTurns([...older, reply], "pages", page, undefined, [], 10000);
  expect(streamed.ticks).toBe(page.ticks);
  expect(streamed.pendingCount).toBe(page.pendingCount);
});
