// Grid line heights (`experiments.typeGrid`, off by default; ui/typeGrid.css). Design C1 of the design
// system decisions (cmuxterm-hq docs/design/design-system-decisions/C-type-fonts-spacing-rows.md):
// "Line height = round4(1.45 x size) on the 4 grid ... caption 11/16, detail 12/16, body (chrome)
// 13/20, field 14/20, title 15/20, heading 20/28." While the switch is on, `<html>` carries
// data-type-grid and every `--text-<step>--line-height` token, at every scope that sets one, takes
// the grid value. Sizes, weights, fonts and the reading content's line height do not change.
import { experimentSwitchOn, subscribeExperimentSwitches } from "../experiments/switches";

/// The switch in Settings > Advanced > Experiments (schemas/settings/source/experiments.json).
export const TYPE_GRID_SWITCH = "typeGrid";

/// On `<html>` while the switch is on; ui/typeGrid.css reads it. Absent, every line height is today's.
export const TYPE_GRID_ATTRIBUTE = "data-type-grid";

/// The 4 grid line height of a type step: round4(1.45 x size), as design C1 sets it.
export function gridLineHeight(size: number): number {
  return Math.round((1.45 * size) / 4) * 4;
}

/// Sets or clears the root attribute from the switch now.
export function applyTypeGrid(doc: Document, on: boolean = experimentSwitchOn(TYPE_GRID_SWITCH)): void {
  const root = doc.documentElement;
  if (on) root.setAttribute(TYPE_GRID_ATTRIBUTE, "");
  else root.removeAttribute(TYPE_GRID_ATTRIBUTE);
}

/// Keeps the root attribute in step with the switch; returns the unsubscribe.
export function installTypeGrid(doc: Document): () => void {
  applyTypeGrid(doc);
  return subscribeExperimentSwitches(() => applyTypeGrid(doc));
}
