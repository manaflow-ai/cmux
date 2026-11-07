// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the empty composer draws the agent's suggested next prompt (Claude Code's prompt suggestions;
/// Leo, 2026-11-03: "i know there's suggested prompts that you can right arrow/tab to do stuff
/// with... maybe we can expose it in cmux-next too"). Gallery `agent-pane.composer-prompt-suggestion`.
export const promptSuggestionLook = defineExperiment({
  id: "prompt-suggestion-look",
  title: "Composer prompt suggestion",
  description:
    "How the agent's suggested next prompt reads in the empty composer. Every arm takes it with Tab or Right-arrow and never sends.",
  arms: {
    keycap: {
      label: "Ghost text + Tab",
      description: "The placeholder's grey with a quiet Tab keycap after it, as the new chat's PR suggestion.",
    },
    plain: {
      label: "Ghost text",
      description: "The placeholder's grey alone, as Claude Code's terminal prompt draws it.",
    },
    italic: {
      label: "Italic ghost text",
      description: "The placeholder's grey in italics, no keycap.",
    },
  },
  defaultArm: "keycap",
});
