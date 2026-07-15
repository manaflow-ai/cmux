import type { Id } from "cmux/browser";
import type { PaneLayoutView } from "./layout";

export const MIN_SPLIT_RATIO = 0.05;
export const MAX_SPLIT_RATIO = 0.95;

type PaneLayoutGroup = Extract<PaneLayoutView, { type: "group" }>;

export interface SplitPointer {
  clientX: number;
  clientY: number;
}

export interface SplitBounds {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface SplitDividerTarget {
  pane: Id;
  dir: "right" | "down";
}

export function clampSplitRatio(ratio: number): number {
  return Math.max(MIN_SPLIT_RATIO, Math.min(MAX_SPLIT_RATIO, ratio));
}

export function splitRatioFromPointer(
  direction: PaneLayoutGroup["direction"],
  pointer: SplitPointer,
  bounds: SplitBounds,
): number | null {
  const extent = direction === "row" ? bounds.width : bounds.height;
  if (extent <= 0) return null;
  const offset = direction === "row"
    ? pointer.clientX - bounds.left
    : pointer.clientY - bounds.top;
  return clampSplitRatio(offset / extent);
}

export function splitRatioToCommit(currentRatio: number, previewRatio: number): number | null {
  const nextRatio = clampSplitRatio(previewRatio);
  return Math.abs(nextRatio - currentRatio) <= 1e-6 ? null : nextRatio;
}

function paneWithoutCrossingDirection(
  node: PaneLayoutView,
  direction: PaneLayoutGroup["direction"],
): Id | null {
  if (node.type === "pane") return node.pane;
  if (node.direction === direction) return null;
  return paneWithoutCrossingDirection(node.first, direction)
    ?? paneWithoutCrossingDirection(node.second, direction);
}

/**
 * Pick a pane whose deepest matching ancestor is this group. A descendant
 * behind a same-direction split would make set-ratio resize that inner split.
 */
export function splitDividerTarget(node: PaneLayoutGroup): SplitDividerTarget | null {
  const pane = paneWithoutCrossingDirection(node.first, node.direction)
    ?? paneWithoutCrossingDirection(node.second, node.direction);
  if (pane === null) return null;
  return { pane, dir: node.direction === "row" ? "right" : "down" };
}
