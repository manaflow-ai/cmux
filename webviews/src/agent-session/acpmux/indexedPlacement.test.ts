import { expect, test } from "bun:test";
import {
  layoutConversation,
  layoutConversationIndexed,
  placeRows,
  visibleLayoutRange,
  type AcpmuxRow,
  type RowHeights,
} from "./model";
import { applyHeightChanges, geometryFromHeights, placeMeasuredRows } from "./conversationGeometry";
import { preserveScrollAnchorTop } from "./conversation/scrollAnchor";

const row = (id: string, kind = "assistant"): AcpmuxRow => ({ id, kind, text: id, version: 1, at: 0 });

test("a report reads only its mounted and held indices at 9k and 90k rows", () => {
  for (const count of [9_000, 90_000]) {
    const estimate = geometryFromHeights(new Float64Array(count).fill(20));
    let reads = 0;
    const next = placeMeasuredRows(
      estimate,
      (at) => {
        reads += 1;
        return at === 4 ? 0 : 31;
      },
      [4, count - 3],
      { layout: estimate, from: count },
    );
    expect(reads).toBe(2);
    expect(next.topAt(count - 3)).toBe((count - 3) * 20 - 20);
    expect(next.totalHeight).toBe(count * 20 - 9);
    expect(estimate.topAt(count - 3)).toBe((count - 3) * 20);
    reads = 0;
    expect(
      placeMeasuredRows(
        estimate,
        () => {
          reads += 1;
          return undefined;
        },
        [],
        {
          layout: next,
          from: count,
        },
      ),
    ).toBe(next);
    expect(reads).toBe(0);
  }
});

test("token estimates preserve drawn heights and an appended row gets its own estimate", () => {
  const before = geometryFromHeights([20, 20, 20]);
  const placed = applyHeightChanges(before, [
    { index: 0, height: 13 },
    { index: 2, height: 40 },
  ]);
  const estimate = applyHeightChanges(before, [{ index: 2, height: 60 }]);
  const revised = placeMeasuredRows(estimate, (at) => (at === 2 ? 40 : undefined), [], {
    layout: placed,
    from: 2,
  });
  expect(revised).toBe(placed);
  const appended = placeMeasuredRows(geometryFromHeights([20, 20, 60, 5]), () => undefined, [], {
    layout: revised,
    from: 3,
  });
  expect(appended.topAt(3)).toBe(73);
  expect(appended.totalHeight).toBe(78);
  expect(revised.count).toBe(3);
});

test("indexed placement matches full placement through reorder, prepend, width and registry reset", () => {
  let rows = [row("a", "user"), row("b"), row("c", "turnSummary")];
  let known: RowHeights = new WeakMap();
  let previous: { rows: AcpmuxRow[]; layout: ReturnType<typeof layoutConversationIndexed> } | undefined;
  const drawn = new Map([["b", 41]]);
  let divisor = 10;
  for (const change of ["initial", "reorder", "prepend", "width", "registry", "truncate"] as const) {
    if (change === "reorder") rows = [rows[1]!, rows[0]!, rows[2]!];
    if (change === "prepend") rows = [row("older"), ...rows];
    if (change === "truncate") rows = rows.slice(1);
    if (change === "registry") {
      known = new WeakMap();
      divisor = 20;
    }
    const width = change === "width" ? 360 : 720;
    const measure = (_row: AcpmuxRow, w: number) => w / divisor;
    const reuse = change === "width" || change === "registry" ? undefined : previous;
    const indexed = layoutConversationIndexed(rows, width, undefined, measure, known, reuse);
    const full = layoutConversation(rows, width, undefined, measure);
    const next = placeMeasuredRows(indexed, (at) => drawn.get(rows[at]!.id), []);
    const expected = placeRows(full, (at) => drawn.get(rows[at]!.id));
    for (let at = 0; at < rows.length; at += 1) {
      expect(next.topAt(at)).toBe(expected.tops[at]);
      expect(next.heightAt(at)).toBe(expected.heights[at]);
    }
    expect(next.totalHeight).toBe(expected.totalHeight);
    expect(visibleLayoutRange(next, 20, 70)).toEqual(visibleLayoutRange(expected, 20, 70));
    previous = { rows, layout: indexed };
  }
});

test("a validated revision boundary avoids reading the unchanged prefix", () => {
  const rows = Array.from({ length: 9_000 }, (_, at) => row(String(at)));
  const known: RowHeights = new WeakMap();
  const before = layoutConversationIndexed(rows, 720, undefined, () => 20, known);
  const revised = [...rows];
  revised[8_999] = { ...revised[8_999]!, version: 2 };
  let reads = 0;
  const counted = new Proxy(revised, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads += 1;
      return Reflect.get(target, key, receiver);
    },
  });
  const next = layoutConversationIndexed(
    counted,
    720,
    undefined,
    () => 21,
    known,
    { rows, layout: before },
    undefined,
    { base: rows, rows: counted, from: 8_999 },
  );
  expect(reads).toBeLessThan(16);
  expect(next.totalHeight).toBe(before.totalHeight + 1);
  expect(before.heightAt(8_999)).toBe(20);
});

test("the anchor compares immutable geometry without compatibility arrays", () => {
  const rows = [row("above"), row("anchor"), row("tail")];
  const before = geometryFromHeights([20, 20, 20]);
  const after = applyHeightChanges(before, [{ index: 0, height: 33.25 }]);
  expect(
    preserveScrollAnchorTop({
      oldLayout: before,
      newLayout: after,
      oldRows: rows,
      newRows: rows,
      liveTop: 27,
      anchorTop: 27,
    }),
  ).toBe(40.25);
  expect(before.topAt(1)).toBe(20);
});
