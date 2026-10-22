// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Whether the transcript draws the thread minimap. `compact` (the default) is the Codex desktop
/// rail from #22228: one 10 px row per prompt, centered on the transcript, the prompts on screen
/// lit. `off` draws nothing at the left edge; Previous and Next Turn and the bookmarked-prompt steps
/// still work. The full-height map (#22784) is gone: Leo, 2026-10-21, "I didn't want the mini map".
/// A stored `full` override from before falls back to this default. Dogfood switches from
/// `cmux.experiments`: {"thread-minimap-layout":"off"}.
export const threadMinimapLayout = defineExperiment({
  id: "thread-minimap-layout",
  title: "Thread minimap layout",
  description: "Whether the transcript draws the compact Codex rail of prompts at its left edge.",
  arms: {
    compact: { label: "Compact", description: "The Codex rail: one 10 px row per prompt, centered on the transcript." },
    off: { label: "Off", description: "No minimap: nothing at the transcript's left edge, only the shared scroller." },
  },
  defaultArm: "compact",
});
