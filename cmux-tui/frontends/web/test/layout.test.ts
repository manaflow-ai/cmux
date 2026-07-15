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
      dir: "right",
      ratio: 0.6,
      a: { type: "leaf", pane: 1 },
      b: {
        type: "split",
        dir: "down",
        ratio: 0.25,
        a: { type: "leaf", pane: 2 },
        b: { type: "leaf", pane: 3 },
      },
    };

    expect(layoutToViewModel(layout)).toEqual({
      type: "group",
      direction: "row",
      firstPercent: 60,
      secondPercent: 40,
      first: { type: "pane", pane: 1 },
      second: {
        type: "group",
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
      dir: "right",
      ratio: 0.5,
      a: { type: "leaf", pane: 1 },
      b: { type: "leaf", pane: 2 },
    };
    expect(layoutToViewModel(layout, 2)).toEqual({ type: "pane", pane: 2 });
    expect(layout.type).toBe("split");
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

  it("maps nested dividers to a pane whose deepest matching split is the group", () => {
    const view = layoutToViewModel({
      type: "split",
      dir: "right",
      ratio: 0.5,
      a: {
        type: "split",
        dir: "right",
        ratio: 0.25,
        a: { type: "leaf", pane: 1 },
        b: { type: "leaf", pane: 2 },
      },
      b: {
        type: "split",
        dir: "down",
        ratio: 0.5,
        a: { type: "leaf", pane: 3 },
        b: { type: "leaf", pane: 4 },
      },
    });
    expect(view.type).toBe("group");
    if (view.type !== "group") throw new Error("expected group");
    expect(splitDividerTarget(view)).toEqual({ pane: 3, dir: "right" });
    expect(view.second.type).toBe("group");
    if (view.second.type !== "group") throw new Error("expected nested group");
    expect(splitDividerTarget(view.second)).toEqual({ pane: 3, dir: "down" });
  });

  it("does not map an outer split when both sides cross a same-direction split", () => {
    const view = layoutToViewModel({
      type: "split",
      dir: "right",
      ratio: 0.5,
      a: {
        type: "split",
        dir: "right",
        ratio: 0.5,
        a: { type: "leaf", pane: 1 },
        b: { type: "leaf", pane: 2 },
      },
      b: {
        type: "split",
        dir: "right",
        ratio: 0.5,
        a: { type: "leaf", pane: 3 },
        b: { type: "leaf", pane: 4 },
      },
    });
    expect(view.type).toBe("group");
    if (view.type !== "group") throw new Error("expected group");
    expect(splitDividerTarget(view)).toBeNull();
  });

  it("skips a set-ratio commit when the ratio is unchanged", () => {
    expect(splitRatioToCommit(0.5, 0.5)).toBeNull();
    expect(splitRatioToCommit(0.5, 0.6)).toBe(0.6);
  });
});
