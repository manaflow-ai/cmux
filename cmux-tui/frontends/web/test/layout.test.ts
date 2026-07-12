import { describe, expect, it } from "vitest";
import type { Layout } from "cmux/browser";
import { layoutToViewModel } from "../src/lib/layout";

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
