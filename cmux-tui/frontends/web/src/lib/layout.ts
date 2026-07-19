import type { Id, Layout } from "cmux/browser";

export type PaneLayoutView =
  | { type: "pane"; pane: Id }
  | { type: "stack"; panes: Id[]; expanded: Id }
  | {
      type: "group";
      split: Id;
      direction: "row" | "column";
      firstPercent: number;
      secondPercent: number;
      first: PaneLayoutView;
      second: PaneLayoutView;
    };

export function visibleStackPanes(
  panes: Id[],
  expanded: Id,
  _visibleHeaders: number | null,
): Id[] {
  if (panes.length === 0 || !panes.includes(expanded)) return [];
  return panes;
}

export function layoutToViewModel(
  layout: Layout,
  zoomedPane: Id | null = null,
  selectedPane: Id | null = null,
): PaneLayoutView {
  if (zoomedPane !== null) return { type: "pane", pane: zoomedPane };
  if (layout.type === "leaf") return { type: "pane", pane: layout.pane };
  if (layout.type === "stack") {
    if (layout.panes.length === 0 || !layout.panes.includes(layout.expanded)) {
      throw new Error("invalid stack layout");
    }
    const expanded = selectedPane !== null && layout.panes.includes(selectedPane)
      ? selectedPane
      : layout.expanded;
    return { type: "stack", panes: layout.panes, expanded };
  }

  const firstPercent = Math.max(5, Math.min(95, layout.ratio * 100));
  if (layout.split === undefined) throw new Error("invalid split layout");
  return {
    type: "group",
    split: layout.split,
    direction: layout.dir === "right" ? "row" : "column",
    firstPercent,
    secondPercent: 100 - firstPercent,
    first: layoutToViewModel(layout.a, null, selectedPane),
    second: layoutToViewModel(layout.b, null, selectedPane),
  };
}
