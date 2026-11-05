// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

export const newTabComposerTrailingGap = defineExperiment({
  id: "new-tab-composer-trailing-gap",
  title: "New Tab composer trailing gap",
  description: "Compare the spacing between the New Tab composer mic and Send controls.",
  arms: {
    tight: {
      label: "Tight",
      description: "A compact 2px action gap.",
    },
    shared: {
      label: "Shared",
      description: "The shared composer action gap used by Claude's composer.",
    },
    roomy: {
      label: "Roomy",
      description: "The legacy 8px action gap.",
    },
  },
  defaultArm: "shared",
});

export type NewTabComposerTrailingGapArm = keyof typeof newTabComposerTrailingGap.arms;

export const newTabComposerTrailingGapArm = (): NewTabComposerTrailingGapArm =>
  experimentArm(newTabComposerTrailingGap);
