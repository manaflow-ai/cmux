import { expect, test } from "bun:test";
import { OrderedRows } from "./direct";
import { rowDelta } from "./rowDelta";
import { turnViewFrom } from "./conversation/turns";
import { layoutConversation } from "./model";
import { transcriptWork } from "./rowWork";

const row = (id: string, at: number, version = 1) => ({
  id,
  at,
  version,
  kind: "assistant" as const,
  text: id,
});

function put(
  rows: OrderedRows,
  id: string,
  value: ReturnType<typeof row>,
  seq: number,
) {
  rows.current = seq;
  rows.set(id, value);
  rows.current = undefined;
}

test("ordered snapshots publish a proven same-slot range without retaining the prior array", () => {
  const rows = new OrderedRows();
  put(rows, "a", row("a", 1), 1);
  put(rows, "b", row("b", 2), 2);
  const first = rows.sorted();
  expect(rowDelta(first)).toMatchObject({ kind: "rebuild", from: 0, to: 2 });

  put(rows, "b", row("b", 3, 2), 3);
  const second = rows.sorted();
  expect(second).not.toBe(first);
  expect(rowDelta(second)).toMatchObject({
    kind: "range",
    previous: first,
    from: 1,
    to: 2,
  });

  put(rows, "c", row("c", 4), 4);
  const third = rows.sorted();
  expect(rowDelta(third)).toMatchObject({
    kind: "range",
    previous: second,
    from: 2,
    to: 3,
  });
});

test("reorder and delete publish rebuild provenance, never an unsafe prefix hint", () => {
  const rows = new OrderedRows();
  put(rows, "a", row("a", 1), 1);
  put(rows, "b", row("b", 2), 2);
  const first = rows.sorted();
  put(rows, "c", row("c", 0), 0);
  const reordered = rows.sorted();
  expect(rowDelta(reordered)).toMatchObject({
    kind: "rebuild",
    previous: first,
    from: 0,
    to: 3,
  });

  rows.delete("a");
  const deleted = rows.sorted();
  expect(rowDelta(deleted)).toMatchObject({
    kind: "rebuild",
    previous: reordered,
    from: 0,
    to: 2,
  });
});

test("proven tail replacement keeps turn and layout prefix work bounded", () => {
  const rows = new OrderedRows();
  for (let index = 0; index < 1_000; index += 1)
    put(rows, `r${index}`, row(`r${index}`, index + 1), index + 1);
  const first = rows.sorted();
  const expanded = new Set<string>();
  const firstTurns = turnViewFrom(first, expanded);
  const firstLayout = layoutConversation(first, 720);
  put(rows, "r999", row("r999", 1_001, 2), 1_001);
  const second = rows.sorted();
  const delta = rowDelta(second)!;
  expect(delta).toMatchObject({
    kind: "range",
    previous: first,
    from: 999,
    to: 1_000,
  });

  transcriptWork.enabled = true;
  transcriptWork.reset();
  turnViewFrom(second, expanded, {}, firstTurns);
  expect(transcriptWork.turnPrefixComparisons).toBe(0);
  transcriptWork.reset();
  layoutConversation(second, 720, new Map(), undefined, undefined, {
    rows: first,
    layout: firstLayout,
    changedFrom: delta.from,
  });
  expect(transcriptWork.layoutPrefixComparisons).toBe(0);
  transcriptWork.enabled = false;
});
