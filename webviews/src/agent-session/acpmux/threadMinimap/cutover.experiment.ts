// l10n-allow-file: experiment labels for the gallery.
import { defineExperiment } from "../../../experiments/experiment";

export const threadMinimapCutover = defineExperiment({
  id: "thread-minimap-cutover",
  title: "Where you left off",
  description: "How the thread rail marks the New line.",
  arms: {
    tick: { label: "Tick", description: "A short rule in the same accent as the New line." },
    band: { label: "Band", description: "A soft band across the rail." },
    dot: { label: "Dot", description: "An accent dot at the edge of the rail." },
  },
  defaultArm: "tick",
});

export type CutoverLook = keyof typeof threadMinimapCutover.arms;
