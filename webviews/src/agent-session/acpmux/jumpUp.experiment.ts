// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Jump up (jumpControl.ts, VirtualTranscript.tsx `JumpToLatest` `up`): the one jump control turning
/// up while a row the reader has not seen lies above the view, and going to the first of them. The default is
/// `off`: Jump to latest stands alone, as the Codex app draws it (Lucas, 2026-11-11: two up arrows
/// read as one too many). `on` lets the control point up; it is never a second disc.
export const jumpUpButton = defineExperiment({
  id: "jump-up",
  title: "Jump up",
  description: "Show the retained Jump up control, or Jump to latest alone.",
  arms: {
    off: {
      label: "No jump-up arrow",
      description: "No jump-up arrow: Jump to latest stands alone (two up arrows read as one too many).",
    },
    on: {
      label: "Jump pair",
      description: "The jump control points up to the first row the reader has not seen while it lies above the view.",
    },
  },
  defaultArm: "off",
});
