// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the composer reads while a chat starts in Cloud (Leo, 2026-11-09: "I can't click into the
/// composer at all to, like potentially type other stuff while it's doing that initial load
/// situation"). In every arm the box takes typing, pastes, drops and dictation, what is typed goes to
/// the started chat's composer as a draft, and Send waits; no arm adds or removes a row, so nothing
/// moves when the start ends. Gallery `agent-pane.cloud-start-composer`.
export const cloudStartComposerLook = defineExperiment({
  id: "cloud-start-composer-look",
  title: "Composer while a Cloud chat starts",
  description: "How the open composer says that what is typed now waits for the Cloud chat.",
  arms: {
    placeholder: {
      label: "Placeholder",
      description:
        "A normal caret; the empty prompt's placeholder says the text goes to the Cloud chat, and Send rests dimmed with the same words as its tooltip.",
    },
    status: {
      label: "Quiet status",
      description: "The empty prompt's placeholder is a quiet “Starting in Cloud…”, Send dimmed.",
    },
    dimmed: {
      label: "Dimmed prompt",
      description: "The usual placeholder; the prompt's text at the muted ink while the start runs, Send dimmed.",
    },
  },
  defaultArm: "placeholder",
});
