// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the line under a sent prompt draws while its agent still starts (Thinking.tsx `starting`),
/// in place of the old "Starting Claude Code… Cancel" (Leo, 2026-11-01: "i hate the "Starting
/// Claude Code... cancel" thing that it starts with"). Every arm keeps the line's one box, so
/// nothing moves when the turn opens; compare them in the gallery's `agent-pane.agent-start`.
export const agentStartLook = defineExperiment({
  id: "agent-start-look",
  title: "Agent start line",
  description: "The line under the first prompt while the agent starts, before its turn opens.",
  arms: {
    thinking: {
      label: "Thinking",
      description: "Thinking with its time and sweep from the send, as the turn then goes on: one look throughout.",
    },
    silent: {
      label: "Silent",
      description: "The line keeps its room and draws nothing until the turn opens, then Thinking.",
    },
    spinner: {
      label: "Spinner",
      description: "A small spinner alone where the words go, then Thinking once the turn opens.",
    },
  },
  defaultArm: "thinking",
});
