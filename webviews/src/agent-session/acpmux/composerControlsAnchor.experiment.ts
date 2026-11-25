// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where Claude's look puts +, the mic and Send as the prompt grows (attachments placed in it, a
/// second line). Leo, 2026-11-18, on a prompt holding a video and a pasted-text card, with + and the
/// mic and Send level with the attachments' top: "the buttons should be at the bottom of the
/// composer". Claude and Codex keep them on the box's bottom edge. Codex's look already
/// has its own row under the prompt (composerLook.css); this varies Claude's compact grid only.
/// Gallery `agent-pane.composer-controls-anchor`.
export const composerControlsAnchor = defineExperiment({
  id: "composer-controls-anchor",
  title: "Composer controls anchor",
  description:
    "Where +, the mic and Send stand when the prompt is taller than one line. On one line every arm draws the same box.",
  arms: {
    "last-line": {
      label: "Last line",
      description: "Beside the prompt's last line, on the box's bottom edge: they never move as the prompt grows.",
    },
    "own-row": {
      label: "Own row",
      description:
        "The prompt spans the box; +, the mic and Send stand on a row under it, as Claude and Codex draw it.",
    },
    "first-line": {
      label: "First line (before)",
      description: "Beside the prompt's first line: level with the top of a prompt that holds attachments.",
    },
  },
  defaultArm: "last-line",
});
