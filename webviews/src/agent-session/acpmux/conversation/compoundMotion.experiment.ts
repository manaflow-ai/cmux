// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the rows move when two or more things move them at once (motionTransaction.ts). Leo,
/// 2026-11-22: "when i send it collapses the compser then sends it to you... but i think we should be
/// able to calculate it out to be like one smooth motion."
export const compoundMotion = defineExperiment({
  id: "compound-motion",
  title: "Compound motion",
  description:
    "A send's composer collapse and its rows, a field growing while a reply streams: one motion on one clock, or each mover on its own.",
  arms: {
    transaction: {
      label: "One motion",
      description:
        "Every move in a frame joins one plan for the thread: one start, one curve, one end (motionTransaction.ts).",
    },
    separate: {
      label: "Each on its own",
      description: "Each mover plays its own glide or moves at once, as before: the send's collapse then its rows.",
    },
  },
  // On since a one-commit send and a queued tall send glide once too (#50851).
  defaultArm: "transaction",
});
