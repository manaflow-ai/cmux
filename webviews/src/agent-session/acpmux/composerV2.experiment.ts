// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The edge light of the refreshed composer (composerV2.ts `useComposerV2`, composerV2.css), shown
/// only while Settings > Advanced > Experiments > Composer Refresh is on, or while a gallery stage arms this
/// experiment (its `arm` query key), so the gallery can show the look with the setting off.
/// Compare the arms in the gallery (view Compare arms), or with the setting on set
/// `cmux.experiments` to `{"composer-v2-look":"halo"}` in the pane's web inspector and reload.
export const composerV2Look = defineExperiment({
  id: "composer-v2-look",
  title: "Composer refresh: the edge light",
  description:
    "The refreshed glass composer while it has focus. Look at whether the light reads as focus without pulling the eye off the words, in light and dark.",
  arms: {
    rim: {
      label: "Rim light",
      description: "A bright edge light traced along the top edge and corners on focus, fading down the sides",
    },
    halo: {
      label: "Halo",
      description: "A soft outer glow around all edges on focus",
    },
    hairline: {
      label: "Hairline",
      description: "A quiet 1 px accent ring on focus, no glow",
    },
  },
  defaultArm: "rim",
});

export type ComposerV2Look = keyof typeof composerV2Look.arms;
