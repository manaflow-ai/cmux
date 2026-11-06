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
  description:
    "The header's mark: the lines' own glyphs side by side, a running-work glyph, no mark at all, or the chat bubble it used to draw.",
  arms: {
    stack: {
      label: "Stacked marks",
      description:
        "The first four lines' own marks side by side, each subagent's in its tone, as the sidebar's status row stacks them; time after the counts.",
    },
    glyph: {
      label: "Running glyph",
      description: "A still running-work ring in the accent; time after the counts.",
    },
    bare: {
      label: "No mark",
      description: "No icon: its slot stays blank, so the counts keep the lines' text column; time after the counts.",
    },
    session: {
      label: "Chat bubble",
      description: "The chat bubble it drew before (agent.session), for comparison; time after the counts.",
    },
  },
  // The ring read as a "3/4 circle" (Leo, 2026-11-01: "WHO THE FUCK EVEN DECIDED TO PUT THAT 3/4
  // CIRCLE ANYWAYS", then "why did you guys not remove the 3/4"), and the blank slot that replaced it
  // read as nothing (Leo, 2026-11-04: "didn't we see better stacked subagents or whatever earlier ...
  // the top of the bar not having anything is weird", beside the sidebar's row of toned sparkles and
  // "8 done"): the header stacks its lines' own marks.
  defaultArm: "stack",
});
