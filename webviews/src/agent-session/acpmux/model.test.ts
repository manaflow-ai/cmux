import { describe, expect, test } from "bun:test";
import { diffRows, visibleLayoutRange, visibleRowRange, type AcpmuxRow, type ConversationLayout } from "./model";

const row = (id: string, version: number): AcpmuxRow => ({ id, version, at: 0, kind: "assistant", text: id });

describe("acpmux row snapshots", () => {
  test("only changed content versions update", () => {
    const before = new Map([["a", row("a", 1)], ["b", row("b", 1)]]);
    expect(diffRows(before, [row("a", 1), row("b", 2), row("c", 1)])).toEqual({
      added: [row("c", 1)],
      updated: [row("b", 2)],
      removed: [],
    });
  });

  test("virtualizer keeps a bounded overscan window", () => {
    expect(visibleRowRange(5000, 12000, 720)).toEqual({ first: 117, last: 141 });
  });

  test("binary-searches exact typed-array tops", () => {
    const layout: ConversationLayout = { tops: new Float64Array([0, 30, 90, 150]), heights: new Float64Array([30, 60, 60, 40]), totalHeight: 190 };
    expect(visibleLayoutRange(layout, 91, 40, 0)).toEqual({ first: 2, last: 3 });
    expect(visibleLayoutRange(layout, 0, 20, 1)).toEqual({ first: 0, last: 2 });
  });
});
