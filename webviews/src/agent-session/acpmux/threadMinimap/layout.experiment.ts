// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The thread minimap's shape. `full` (the default) spans the transcript's height: every message
/// sits where it is in the chat, prompts and replies drawn apart, with a bar for what is on screen
/// (Leo, 2026-10-20: the Codex-sized rail "feels short"). `compact` is the Codex desktop rail:
/// one 10 px row per prompt, centered. Dogfood switches from `cmux.experiments`:
/// {"thread-minimap-layout":"compact"}.
export const threadMinimapLayout = defineExperiment({
  id: "thread-minimap-layout",
  title: "Thread minimap layout",
  description: "Whether the minimap spans the whole transcript height or is the compact Codex rail.",
  arms: {
    full: {
      label: "Full height",
      description: "Spans the transcript: every message at its place, prompts and replies apart, a bar for the view.",
    },
    compact: { label: "Compact", description: "The Codex rail: one 10 px row per prompt, centered on the transcript." },
  },
  defaultArm: "full",
});
