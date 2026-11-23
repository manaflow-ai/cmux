// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the chat's one status line after a failed turn reads (QueueStatusLine.tsx). Leo, 2026-11-23, on
/// "Retrying (1/4) after a capacity error" over "Paused after an error: API Error: 503 ...": "this looks
/// ass idk". Every arm says one plain state with the retry's countdown and keeps the raw error behind
/// Details; they differ in hierarchy. Compare them in the gallery's `agent-pane.queue-status`.
export const queueStatusLook = defineExperiment({
  id: "queue-status-look",
  title: "Failed turn status line",
  description:
    "How the one status line over the queue reads after a failed turn: its mark, its words and its countdown.",
  arms: {
    inline: {
      label: "Inline: a mark, the state in ink, the countdown muted",
      description:
        "One 28 px line: the retry mark, 'Waiting for capacity' in the text ink, then 'retrying in 9:42 · 1 of 4' muted, Details and Resume at the end.",
    },
    stacked: {
      label: "Stacked: the state over its countdown",
      description: "Two lines: the state in ink, the countdown and try count under it, muted.",
    },
    dot: {
      label: "Dot: an attention dot before the words",
      description: "The inline line with a small attention-hue dot in place of the mark.",
    },
  },
  // One quiet line reads as the hat's other lines do (the surge row, the goal row), and leaves the
  // queue's rows their room; the stacked arm doubled the strip's height for words a line holds.
  defaultArm: "inline",
});
