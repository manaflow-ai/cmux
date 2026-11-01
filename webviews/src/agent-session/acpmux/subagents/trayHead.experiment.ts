// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The running tray's header mark (SubagentTray.tsx). It is a fixed icon, never the spinner: the
/// spinner stays on each working line (#27103; Leo: "I NEVER SAID TO PUT THE SPINNER HERE"). The chat
/// bubble it drew read as a message, not as work that runs in the background. Every arm keeps the
/// counts, the elapsed time as quiet meta right after them, and the chevron in the one trailing column
/// the lines share. Compare them in the gallery's `agent-pane.subagent-tray-head`.
export const trayHeadLook = defineExperiment({
  id: "subagent-tray-head",
  title: "Running tray header",
  description: "The header's fixed mark: a running-work glyph, no mark at all, or the chat bubble it used to draw.",
  arms: {
    glyph: {
      label: "Running glyph",
      description: "A still running-work ring in the accent; time after the counts.",
    },
    bare: {
      label: "No mark",
      description: "No icon: the counts start at the row inset; time after the counts.",
    },
    session: {
      label: "Chat bubble",
      description: "The chat bubble it drew before (agent.session), for comparison; time after the counts.",
    },
  },
  defaultArm: "glyph",
});
