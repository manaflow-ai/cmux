// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the live line at the bottom of a running turn (Thinking.tsx) says the turn's tokens. Claude
/// Code desktop says one count, "3m 2s · 47.4k tokens" (Leo, 2026-11-03: "comparing claude code's to
/// ours, we're not faithfully following how they're doing stuff"); ours said "↓ 7.9K out ↑ 2.7M in".
/// The count is the turn's generated output, the number Anthropic talks about (TurnTokens.tsx), so
/// nothing is folded into it; the split stays on the hover and on a finished turn's footer.
/// Compare them in the gallery's `agent-pane.claude-code-tool-rows`.
export const liveLineTokens = defineExperiment({
  id: "live-line-tokens",
  title: "Live line tokens",
  description:
    "The running turn's tokens on its live line: one count as Claude Code says it, or output and input apart.",
  arms: {
    total: {
      label: "One count",
      description: "\"47.4K tokens\": the turn's output, as Claude Code's live line; the split on hover.",
    },
    split: {
      label: "Out and in",
      description: '"↓ 47.4K out ↑ 2.7M in": the earlier look, output then everything the model read.',
    },
  },
  defaultArm: "total",
});
