// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The thread minimap's shape. `compact` (the default) is the wave: the Codex desktop rail from
/// #22228, one 10 px row per prompt centered on the transcript, the prompts on screen lit as a band
/// that follows the scroll, and the ticks under the pointer magnifying like the Dock. It is back as
/// the default because the full-height map that replaced it (#22784) was not what Leo asked for
/// (2026-10-22: "Why did you turn it into a whole mini map? ... I didn't want the mini map." and
/// "IT'S JUST THE FUCKING LINES THEY DONT FUCKIG ANIMTATE"). Its list never draws a scroller and sits
/// over the transcript (position sticky, no height), so it shifts no layout on a tab switch. `full`
/// spans the transcript's height: every message at its place, prompts and replies drawn apart, with
/// a bar for what is on screen (#22784). `off` draws none (#23735); Previous and Next Turn and the
/// bookmarked-prompt steps still work. Dogfood switches from `cmux.experiments`:
/// {"thread-minimap-layout":"full"} or {"thread-minimap-layout":"off"}.
export const threadMinimapLayout = defineExperiment({
  id: "thread-minimap-layout",
  title: "Thread minimap layout",
  description:
    "Whether the transcript draws a minimap at all, and if so whether it spans the transcript height or is the compact Codex rail.",
  arms: {
    off: { label: "Off", description: "No minimap: nothing at the transcript's left edge, only the shared scroller." },
    full: {
      label: "Full height",
      description: "Spans the transcript: every message at its place, prompts and replies apart, a bar for the view.",
    },
    compact: { label: "Compact", description: "The Codex rail: one 10 px row per prompt, centered on the transcript." },
  },
  defaultArm: "compact",
});
