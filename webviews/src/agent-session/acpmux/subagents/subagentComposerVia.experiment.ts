// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a subagent's composer names the chat that passes its message on ("Sent through <chat>",
/// SubagentComposer.tsx). Leo, 2026-11-19: "the composer is kinda odd looking for subagents"; the
/// line was a loose centered caption under a composer that drew none of the chat composer's
/// controls. Compare the arms in the gallery's `agent-pane.subagents` (`own-pane-via-*`).
export const subagentComposerVia = defineExperiment({
  id: "subagent-composer-via",
  title: "Subagent composer: where the routing note sits",
  description:
    "The note naming the chat a subagent's message goes through: the quiet row's left (where the chat's mode sits), its right (where the model sits), a chip with the route icon, or the old caption under the box.",
  arms: {
    foot: {
      label: "Quiet row, left",
      description:
        "The quiet row under the box, where the chat's composer shows its mode: the same row, inset and ink as the chat's.",
    },
    end: {
      label: "Quiet row, right",
      description: "The quiet row under the box, right-aligned where the chat's composer shows its model.",
    },
    chip: {
      label: "Route chip",
      description: "The quiet row's left, as a route icon and the chat's name; the full sentence is its tooltip.",
    },
    caption: {
      label: "Caption (before)",
      description: "The centered caption under the box, as before Leo's 2026-11-19 report.",
    },
  },
  defaultArm: "foot",
});
