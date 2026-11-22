// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How a chat starting in Cloud asks its question (CloudStartAsk.tsx): its first Claude login, the
/// login copy consent, Codex's sign-in consent or device code, in the start's card under the person's
/// message, never a dialog over the window. Compare the arms in the gallery's `agent-pane.cloud-start`
/// (the `ask-*` variants).
export const cloudStartAskLook = defineExperiment({
  id: "cloud-start-ask",
  title: "Cloud start question",
  description: "Where a Cloud start's question and its buttons go in the start card.",
  arms: {
    inline: {
      label: "Inline",
      description: "The question as the chat's own text under the message, its buttons on one line under it.",
    },
    sheet: {
      label: "Glass sheet",
      description: "The question in a popover-level glass panel inside the card, its buttons at the panel's foot.",
    },
    banner: {
      label: "Banner",
      description: "One line: the question's title with its buttons trailing; the body in muted lines under it.",
    },
  },
  defaultArm: "inline",
});
