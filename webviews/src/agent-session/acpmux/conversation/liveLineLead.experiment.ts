// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the live line at the bottom of a running turn (Thinking.tsx) starts. Every other row there
/// ("Sent a message, ran 5 commands", "Subagent finished", a received line) draws its glyph in the
/// shared icon column and its words on the text column; the line with an empty slot read as a second
/// line hung under the row above it (Leo, 2026-11-03, on "Sent a message, finished 3 background
/// tasks, ran 5 commands" over "Thinking · 1m 23s total · 3.2K tokens": a bad indent, its icon
/// column not lining up with the other rows). `mark`, the default, gives it a still glyph of what it
/// names in that column, so it is a row of its own; the shimmer stays its only working sign. Compare
/// them in the gallery's `agent-pane.live-line-lead`.
export const liveLineLead = defineExperiment({
  id: "live-line-lead",
  title: "Live line lead",
  description: "How the running turn's live line starts: a still glyph in the icon column, an empty slot, or flush.",
  arms: {
    mark: {
      label: "Glyph in the icon column",
      description:
        "A still glyph of what the line names (a clock, the terminal, the envelope) in the rows' icon column; words on the text column.",
    },
    slot: {
      label: "Empty slot",
      description: "The earlier look (#33157): no glyph, the words on the text column under the row above.",
    },
    flush: {
      label: "Flush",
      description: "No glyph, the words on the icon column's left edge, as a reply's text starts.",
    },
  },
  defaultArm: "mark",
});
