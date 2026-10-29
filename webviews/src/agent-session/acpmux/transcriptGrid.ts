// The virtual stack reads the same declarative lengths as the generated CSS grid tokens.
import grid from "../../../../schemas/layout-grid/layout-grid.json";

export const gridLength = (name: string): number => {
  const metric = grid.metrics.find((value) => value.name === name);
  if (!metric) throw new Error(`Missing layout grid metric: ${name}`);
  return metric.pt;
};
export const TRANSCRIPT_BLOCK_GAP = gridLength("gap-block");
export const TRANSCRIPT_INNER_GAP = gridLength("gap-inner");
// The dependency adds this token in its next revision (CSS uses the same migration fallback).
export const TRANSCRIPT_TURN_GAP = grid.metrics.find((value) => value.name === "gap-turn")?.pt ?? 32;
export const TRANSCRIPT_COMPOSER_GAP = gridLength("gap-composer");
