import { describe, expect, it } from "vitest";
import type { Layout } from "cmux/browser";
import { layoutToViewModel } from "../src/lib/layout";
import {
  clampSplitRatio,
  splitDividerTarget,
  splitRatioFromPointer,
  splitRatioToCommit,
} from "../src/lib/splitDrag";

describe("layoutToViewModel", () => {
  it("maps nested split directions and ratios to flex percentages", () => {
    const layout: Layout = {
      type: "split",
      split: 10,
      dir: "right",
      ratio: 0.6,
      a: { type: "leaf", pane: 1 },
      b: {
        type: "split",
        split: 11,
        dir: "down",
        ratio: 0.25,
        a: { type: "leaf", pane: 2 },
        b: { type: "leaf", pane: 3 },
      },
    };

    expect(layoutToViewModel(layout)).toEqual({
      type: "group",
      split: 10,
      direction: "row",
      firstPercent: 60,
      secondPercent: 40,
      first: { type: "pane", pane: 1 },
      second: {
        type: "group",
        split: 11,
        direction: "column",
        firstPercent: 25,
        secondPercent: 75,
        first: { type: "pane", pane: 2 },
        second: { type: "pane", pane: 3 },
      },
    });
  });

  it("renders only the zoomed pane without rewriting the source layout", () => {
    const layout: Layout = {
      type: "split",
      split: 12,
      dir: "right",
      ratio: 0.5,
      a: { type: "leaf", pane: 1 },
      b: { type: "leaf", pane: 2 },
    };
    expect(layoutToViewModel(layout, 2)).toEqual({ type: "pane", pane: 2 });
    expect(layout.type).toBe("split");
  });

  it("rejects split snapshots without protocol-8 split IDs", () => {
    expect(() => layoutToViewModel({
      type: "split",
      dir: "right",
      ratio: 0.5,
      a: { type: "leaf", pane: 1 },
      b: { type: "leaf", pane: 2 },
    })).toThrow("invalid split layout");
  });
});

describe("split drag", () => {
  it("computes row and column ratios from the pointer within the group", () => {
    const bounds = { left: 100, top: 50, width: 400, height: 200 };
    expect(splitRatioFromPointer("row", { clientX: 340, clientY: 0 }, bounds)).toBe(0.6);
    expect(splitRatioFromPointer("column", { clientX: 0, clientY: 100 }, bounds)).toBe(0.25);
  });

  it("clamps pointer ratios to the server bounds", () => {
    const bounds = { left: 100, top: 50, width: 400, height: 200 };
    expect(splitRatioFromPointer("row", { clientX: 0, clientY: 0 }, bounds)).toBe(0.05);
    expect(splitRatioFromPointer("column", { clientX: 0, clientY: 500 }, bounds)).toBe(0.95);
    expect(clampSplitRatio(-1)).toBe(0.05);
    expect(clampSplitRatio(2)).toBe(0.95);
  });

  it("maps nested dividers to their exact protocol-8 split IDs", () => {
    const view = layoutToViewModel({
      type: "split",
      split: 20,
      dir: "right",
      ratio: 0.5,
      a: {
        type: "split",
        split: 21,
        dir: "right",
        ratio: 0.25,
        a: { type: "leaf", pane: 1 },
        b: { type: "leaf", pane: 2 },
      },
      b: {
        type: "split",
        split: 22,
        dir: "down",
        ratio: 0.5,
        a: { type: "leaf", pane: 3 },
        b: { type: "leaf", pane: 4 },
      },
    });
    expect(view.type).toBe("group");
    if (view.type !== "group") throw new Error("expected group");
    expect(splitDividerTarget(view)).toEqual({ split: 20 });
    expect(view.second.type).toBe("group");
    if (view.second.type !== "group") throw new Error("expected nested group");
    expect(splitDividerTarget(view.second)).toEqual({ split: 22 });
  });

  it("targets an outer split exactly across same-direction descendants", () => {
    const view = layoutToViewModel({
      type: "split",
      split: 30,
      dir: "right",
      ratio: 0.5,
      a: {
        type: "split",
        split: 31,
        dir: "right",
        ratio: 0.5,
        a: { type: "leaf", pane: 1 },
        b: { type: "leaf", pane: 2 },
      },
      b: {
        type: "split",
        split: 32,
        dir: "right",
        ratio: 0.5,
        a: { type: "leaf", pane: 3 },
        b: { type: "leaf", pane: 4 },
      },
    });
    expect(view.type).toBe("group");
    if (view.type !== "group") throw new Error("expected group");
    expect(splitDividerTarget(view)).toEqual({ split: 30 });
  });

  it("skips a set-ratio commit when the ratio is unchanged", () => {
    expect(splitRatioToCommit(0.5, 0.5)).toBeNull();
    expect(splitRatioToCommit(0.5, 0.6)).toBe(0.6);
  });
});
