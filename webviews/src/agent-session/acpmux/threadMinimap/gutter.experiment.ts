// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail fits a narrow pane's gutter (Leo, 2026-11-01: "also when things shrink it should
/// be able to be more easily hoverable it's just kinda flickering in and out of being accessible at
/// smaller viewpoints even though it certainly has enough space just shrink its padding more it can
/// even have a dedicated space for more"). `tight`, the default, shrinks the rail's inset to the
/// smallest spacing step and its hit width to the compact step before anything hides, so the resting
/// rail fits the page edge every transcript keeps (`--cv-edge`) and stays drawn and hoverable at every
/// width; hovering it widens it over the text for the magnified ticks. `edge-strip` is the earlier
/// placement (2026-10-28): a wider minimum inset, hidden at rest once it would overlap the text, with
/// a hover strip at the pane edge. `dimmed` is that placement drawn at 40% while it overlaps (#30190).
/// Dogfood switches from `cmux.experiments`: {"thread-minimap-gutter":"edge-strip"}.
export const threadMinimapGutter = defineExperiment({
  id: "thread-minimap-gutter",
  title: "Prompt rail gutter",
  description: "How the prompt rail fits a narrow pane: shrink its padding first, or hide it behind an edge strip.",
  arms: {
    tight: {
      label: "Tight gutter",
      description: "The inset shrinks to 4 px and the hit width to 12 px first: the rail always fits the page edge.",
    },
    "edge-strip": {
      label: "Edge strip",
      description: "An 8 px minimum inset; hidden at rest once it would overlap the text, revealed from the pane edge.",
    },
    dimmed: {
      label: "Dimmed overlap",
      description: "The edge strip's placement, drawn at 40% over the text instead of hidden.",
    },
  },
  defaultArm: "tight",
});
