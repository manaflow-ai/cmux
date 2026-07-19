import type { Id, Layout } from "cmux/browser";

export type PaneLayoutView =
  | { type: "pane"; pane: Id }
  | {
      type: "group";
      split: Id;
      direction: "row" | "column";
      firstPercent: number;
      secondPercent: number;
      first: PaneLayoutView;
      second: PaneLayoutView;
    };

export function layoutToViewModel(layout: Layout, zoomedPane: Id | null = null): PaneLayoutView {
  if (zoomedPane !== null) return { type: "pane", pane: zoomedPane };
  if (layout.type === "leaf") return { type: "pane", pane: layout.pane };

  const firstPercent = Math.max(5, Math.min(95, layout.ratio * 100));
  if (layout.split === undefined) throw new Error("invalid split layout");
  return {
    type: "group",
    split: layout.split,
    direction: layout.dir === "right" ? "row" : "column",
    firstPercent,
    secondPercent: 100 - firstPercent,
    first: layoutToViewModel(layout.a),
    second: layoutToViewModel(layout.b),
  };
}
