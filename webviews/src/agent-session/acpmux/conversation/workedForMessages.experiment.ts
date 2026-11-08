// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a closed "Worked for" counts the messages between agents folded in it: the messages that
/// woke the chat and the ones sent and received among its calls (turns.ts `shapeTurn`). Leo,
/// 2026-11-07: "Maybe it's fine to count as a regular tool call." The default counts them as calls:
/// the label keeps the time alone, as Codex's does, and the turn's call count takes them.
/// Compare in `agent-pane.messages-fold-into-worked`.
export const workedForMessages = defineExperiment({
  id: "worked-for-messages",
  title: "Messages in a closed Worked for",
  description: "How a finished turn's closed Worked for counts the messages between agents folded in it.",
  arms: {
    calls: {
      label: "Counted as calls",
      description: "Worked for 1m 17s; each message counts as one of the turn's calls.",
    },
    time: {
      label: "Time alone",
      description: "Worked for 1m 17s; the messages fold in uncounted.",
    },
    messages: {
      label: "Messages named",
      description: "Worked for 1m 17s, sent a message, received 3 messages.",
    },
  },
  defaultArm: "calls",
});
