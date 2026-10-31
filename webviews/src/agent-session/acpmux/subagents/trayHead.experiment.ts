// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The running tray's header mark (SubagentTray.tsx). The chat bubble it drew read as a message, not
/// as work that runs in the background. Every arm keeps the counts, the elapsed time as quiet meta
/// right after them, and the chevron in the one trailing column the lines share. Compare them in the
/// gallery's `agent-pane.subagent-tray-head`.
export const trayHeadLook = defineExperiment({
  id: "subagent-tray-head",
  title: "Running tray header",
  description:
    "The header's mark: the shared spinner while anything under it runs, a static running-work glyph, or no mark at all.",
  arms: {
    spinner: {
      label: "Spinner",
      description: "The shared spinner while work runs (a still glyph once nothing does); time after the counts.",
    },
    glyph: {
      label: "Running glyph",
      description: "A still running-work glyph in the accent; time after the counts.",
    },
    bare: {
      label: "No mark",
      description: "No icon: the counts start at the row inset; time after the counts.",
    },
  },
  defaultArm: "spinner",
});
