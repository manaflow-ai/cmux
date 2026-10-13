// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Side questions (`/btw`, SideQuestion.tsx): off until the pane's design takes them in. Dogfood:
/// set `cmux.experiments` to `{"side-question":"on"}` in the pane's web inspector and reload.
export const sideQuestion = defineExperiment({
  id: "side-question",
  title: "Side question",
  description: "The composer's /btw asks about the chat without adding to it; the answer shows above the composer.",
  arms: {
    off: { label: "Off", description: "No /btw command." },
    on: { label: "On", description: "/btw asks a side question (acpmux `_acpmux/ask`)." },
  },
  defaultArm: "off",
});
