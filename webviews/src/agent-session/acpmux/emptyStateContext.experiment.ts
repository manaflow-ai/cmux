// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Contextual copy and quiet starts for empty surfaces. `contextual` ships (Leo, 2026-11-22: "the taste ones i
/// agree with all actually"); `now`, the earlier copy and controls, stays as an arm to compare against.
export const emptyStateContext = defineExperiment({
  id: "empty-state-context",
  title: "Empty state context",
  description: "Names empty search queries, offers one next step, and uses recent folder context to seed a new chat.",
  arms: {
    now: {
      label: "Current empty states",
      description: "Keep the existing copy and controls.",
    },
    contextual: {
      label: "Contextual empty states",
      description: "Name the query, give one next step, and show up to three quiet chat starts.",
    },
  },
  defaultArm: "contextual",
});
