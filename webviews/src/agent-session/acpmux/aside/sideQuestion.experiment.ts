// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Side sessions (`/btw`, sideSessions.ts) until the Labs flag `sideSessions` replaces this. Dogfood:
/// set `cmux.experiments` to `{"side-question":"on"}` in the pane's web inspector and reload.
export const sideQuestion = defineExperiment({
  id: "side-question",
  title: "Side question",
  description: "The composer's /btw opens a read-only side session about the chat beside it; the chat keeps running.",
  arms: {
    off: { label: "Off", description: "No /btw command." },
    on: { label: "On", description: "/btw opens a side session (acpmux `_acpmux/btw`)." },
  },
  defaultArm: "off",
});
