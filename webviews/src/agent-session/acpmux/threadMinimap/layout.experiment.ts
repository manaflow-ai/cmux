// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The thread minimap's shape. `off` (the default) draws no minimap: the transcript's left edge is
/// empty and its one scroller is the shared thin overlay one (Leo, 2026-10-21, on the nightly: "HOW
/// DID THIS SCROLL THING GET IN AGAIN"). Previous and Next Turn and the bookmarked-prompt steps
/// still work without it. `full` spans the transcript's height: every message sits where it is in
/// the chat, prompts and replies drawn apart, with a bar for what is on screen (#22784). `compact`
/// is the Codex desktop rail: one 10 px row per prompt, centered (#22228). Dogfood switches from
/// `cmux.experiments`: {"thread-minimap-layout":"full"} or {"thread-minimap-layout":"compact"}.
export const threadMinimapLayout = defineExperiment({
  id: "thread-minimap-layout",
  title: "Thread minimap layout",
  description: "Whether the transcript draws a minimap at all, and if so whether it spans the transcript height or is the compact Codex rail.",
  arms: {
    off: { label: "Off", description: "No minimap: nothing at the transcript's left edge, only the shared scroller." },
    full: {
      label: "Full height",
      description: "Spans the transcript: every message at its place, prompts and replies apart, a bar for the view.",
    },
    compact: { label: "Compact", description: "The Codex rail: one 10 px row per prompt, centered on the transcript." },
  },
  defaultArm: "off",
});
