// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the composer's context ring moves when the share used changes: a compaction drops it, a turn
/// raises it (Leo, 2026-11-07: "after a compaction ... it goes back down. I feel like that should,
/// like, play a cute little, like, eased animation that goes down"). Every arm draws the same ring
/// at rest, shows a chat's own value at once when it opens or is switched to, and changes in one
/// frame under Reduce Motion. Gallery `agent-pane.context-ring-motion`.
export const contextRingMotion = defineExperiment({
  id: "context-ring-motion",
  title: "Context ring motion",
  description:
    "How the context ring goes from one reading to the next (85% to 12% on a compaction, 40% to 55% on a turn). The percent beside the ring, where a look shows one, moves with it or jumps.",
  arms: {
    ease: {
      label: "CSS ease-out, percent counts",
      description:
        "A CSS transition on a registered number property eases the arc over 600 ms; the percent counts along from the same property, so the two never disagree.",
    },
    "ease-number-jumps": {
      label: "CSS ease-out, percent jumps",
      description: "The same eased arc, but the percent shows the new value at once while the arc is still moving.",
    },
    spring: {
      label: "Spring",
      description: "The shared spring curve over 600 ms: a quicker start and a slight settle past the new value.",
    },
    instant: {
      label: "Instant (before)",
      description: "Before: the ring jumps to the new reading in one frame.",
    },
  },
  defaultArm: "ease",
});
