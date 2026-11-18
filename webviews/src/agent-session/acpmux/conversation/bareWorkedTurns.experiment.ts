// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What finished turns that drew nothing but their closed "Worked for" draw (turns.ts `bareWorked`):
/// wakes and other agents' messages the agent answered with tools alone. Austin's chat, 2026-11-17,
/// stacked five such lines with nothing between them (Leo: "we sometimes have weird ui like this").
/// Compare in `agent-pane.bare-worked-turns`.
export const bareWorkedTurns = defineExperiment({
  id: "bare-worked-turns",
  title: "Turns with nothing but Worked for",
  description: "How consecutive finished turns that said nothing to the person draw.",
  arms: {
    joined: {
      label: "One joined line",
      description: "Worked for 1m 40s: one line over their summed time; opening it opens each turn.",
    },
    hidden: {
      label: "Hidden",
      description: "No line at all: the turns draw nothing until a reply.",
    },
    separate: {
      label: "One line each",
      description: "Worked for 37s, Worked for 3s, Worked for 1m: each its own line, as before.",
    },
  },
  defaultArm: "joined",
});
