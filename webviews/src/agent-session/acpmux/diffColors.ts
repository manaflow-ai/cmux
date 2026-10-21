// Diff Colors (Settings > Diff Viewer, `diff.colors`), pushed by the host as the `diffColors`
// event (Swift AgentPaneView+DiffColors): Muted and Standard mark the page (`data-diff-colors`),
// and styles.css recolors `--acpmux-add` and `--acpmux-del` from it, as appearance.ts does in the
// diff tabs. Theme, the default, clears the mark. Muted also takes quieter row and word tints
// (diffWeight.ts `applyDiffTints`).

import { applyDiffTints } from "../../diffWeight";

const MODES = new Set(["muted", "standard"]);

export function setAgentDiffColors(value: unknown) {
  const root = document.documentElement;
  if (typeof value === "string" && MODES.has(value)) root.dataset.diffColors = value;
  else delete root.dataset.diffColors;
  applyDiffTints(root.style, root.dataset.diffColors);
}

declare global {
  interface Window {
    /// The old host's script for the `diffColors` event.
    cmuxAcpmuxDiffColors?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxDiffColors = setAgentDiffColors;
