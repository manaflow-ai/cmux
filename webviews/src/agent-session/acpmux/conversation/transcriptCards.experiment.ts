// l10n-allow-file: experiment labels for the developer gallery.
import { defineExperiment } from "../../../experiments/experiment";

// RFD 0008, looks/codex-look/SHOTS.md: opened tool output and edited-file cards,
// borderless. Keep the composer and every existing default unchanged.
export const transcriptCards = defineExperiment({
  id: "transcript-cards",
  title: "Borderless transcript cards",
  description: "Compare the current cards with the faint, borderless dark look from RFD 0008.",
  arms: {
    current: {
      label: "Current",
      description: "Keep the active theme's card surfaces and outlines.",
    },
    borderless: {
      label: "Borderless dark",
      description:
        "A faint white fill and transparent card outlines, scoped to the transcript. Dark-only paint stays unchanged over a light theme.",
    },
  },
  defaultArm: "current",
});
