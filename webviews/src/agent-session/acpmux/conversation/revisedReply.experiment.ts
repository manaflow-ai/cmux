// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a reply the agent sent again after a Stop hook shows (design/revised-reply.md). Leo,
/// 2026-11-14, on the same report drawn twice: "why did u send this twice?". In every arm the new
/// reply takes the first one's row, which shows the first text until the new one has streamed, so
/// the transcript never draws the reply twice and nothing below it moves. Compare the arms in the
/// gallery's `agent-pane.revised-reply`.
export const revisedReplyLook = defineExperiment({
  id: "revised-reply-look",
  title: "Revised reply",
  description: "How a reply the agent sent again after a Stop hook says it replaced the first one.",
  arms: {
    word: {
      label: "Revised word",
      description:
        "A muted Revised under the reply (Revising… while the new one streams); a click opens the first version under it.",
    },
    silent: {
      label: "Silent swap",
      description: "The new reply replaces the first in place, with no word; the first version is gone.",
    },
    stack: {
      label: "Earlier version fold",
      description: "A closed Earlier version fold over the reply, which opens the first version above it.",
    },
  },
  defaultArm: "word",
});
