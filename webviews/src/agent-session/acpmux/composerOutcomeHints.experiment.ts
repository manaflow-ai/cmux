// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the empty composer names its responder and how the slash/mention lists preview their next
/// action. The default keeps the current composer copy and rows unchanged.
///
/// Leo 2026-11-22 09:50Z: "50020 prob dont do as default bc we can err on the side of being more
/// minimal/assuming people more or less know what to do. but this is good as tips". So the last three
/// arms keep today's placeholder and rows, and show the long placeholder, every / row's description
/// and the Return keycap only on demand (composerOutcomeHintsModel.ts): `tip` a once-per-install
/// feature tip above the composer, `hint` a quiet "?" at the composer's edge, `option` while Option
/// is held, as the harness updates list shows its versions (useOptionHeld.ts).
export const composerOutcomeHints = defineExperiment({
  id: "composer-outcome-hints",
  title: "Composer outcome hints",
  description: "How the composer shows the responding agent and the result of choosing a menu row.",
  arms: {
    now: {
      label: "Current",
      description: "Keep the current placeholder and slash and mention rows.",
    },
    agent: {
      label: "Agent name",
      description: "Name the agent that will answer in the empty composer.",
    },
    modes: {
      label: "Agent + modes",
      description: "Name the agent and show the / command and @ file modes in the placeholder.",
    },
    outcomes: {
      label: "Outcome hints",
      description: "Show the agent and modes, then preview each row's action and description.",
    },
    tip: {
      label: "Tip, once",
      description: "Today's composer; a feature tip above it, once per install, says what / and @ do.",
    },
    hint: {
      label: "? at the edge",
      description:
        "Today's composer; a quiet ? at its edge shows the descriptions, Return keycap and long placeholder.",
    },
    option: {
      label: "While Option is held",
      description: "Today's composer; holding Option shows the descriptions, Return keycap and long placeholder.",
    },
  },
  defaultArm: "now",
});
