// The virtual stack reads the same declarative lengths as the generated CSS grid tokens.
import grid from "../../../../schemas/layout-grid/layout-grid.json";

export const gridLength = (name: string): number => {
  const metric = grid.metrics.find((value) => value.name === name);
  if (!metric) throw new Error(`Missing layout grid metric: ${name}`);
  return metric.pt;
};
export const TRANSCRIPT_BLOCK_GAP = gridLength("gap-block");
export const TRANSCRIPT_INNER_GAP = gridLength("gap-inner");
export const TRANSCRIPT_TURN_GAP = gridLength("gap-turn");
export const TRANSCRIPT_COMPOSER_GAP = gridLength("gap-composer");
