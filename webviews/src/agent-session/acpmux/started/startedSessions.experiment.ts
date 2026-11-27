// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Started session cards (StartedSessionCard.tsx): off by default. To dogfood in the app, set
/// `cmux.experiments` to `{"started-session-cards":"on"}` in the pane's web inspector and reload.
export const startedSessionCards = defineExperiment({
  id: "started-session-cards",
  title: "Started session cards",
  description:
    "The chats this chat's agent started in a turn show as one card after that turn's reply, each with its status and pull request; a chat's name in a reply links to it.",
  arms: {
    off: { label: "Off", description: "Started chats show only in the sidebar." },
    on: { label: "On", description: "Started chats show as cards and name chips in the transcript." },
  },
  defaultArm: "off",
});
