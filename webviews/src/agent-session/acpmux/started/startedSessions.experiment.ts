// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Started session cards (StartedSessionCard.tsx): on by default. To turn them off in the app, set
/// `cmux.experiments` to `{"started-session-cards":"off"}` in the pane's web inspector and reload.
export const startedSessionCards = defineExperiment({
  id: "started-session-cards",
  title: "Started session cards",
  description:
    "Each chat this chat's agent started shows as a card in the transcript, with what it does now, its pull requests and a status dot; its name in a reply links to it.",
  arms: {
    off: { label: "Off", description: "Started chats show only in the sidebar." },
    on: { label: "On", description: "Started chats show as cards and name chips in the transcript." },
  },
  defaultArm: "on",
});
