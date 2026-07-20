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
  split: Id;
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

export function splitDividerTarget(node: PaneLayoutGroup): SplitDividerTarget {
  return { split: node.split };
}
