// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the compact rail draws a bookmarked prompt at rest. It used to draw its tick and dot at full
/// opacity, the brightest thing on the rail; Leo (2026-10-25): "when I bookmark something, it
/// shouldn't be just at the full brightness ... It should be, like, grayed out. That's how ChatGPT
/// does it". ChatGPT's rail keeps the bookmarked tick grey, a step over the resting ones, with a small
/// grey dot, and brightens it only on hover. Every arm keeps the theme's resting color (the muted
/// text) and differs only in opacity; a hovered or focused bookmarked tick is the text in all of them.
/// The gallery compares the arms side by side; `grey-70` (the default) reads as marked without
/// competing with the lit band (75%) or a hovered tick (100%). Dogfood switches from
/// `cmux.experiments`: {"thread-minimap-mark":"grey-55"}.
export const threadMinimapMark = defineExperiment({
  id: "thread-minimap-mark",
  title: "Thread minimap bookmarked tick",
  description:
    "How bright the compact rail draws a bookmarked prompt's tick and dot at rest, over resting ticks at 40%.",
  arms: {
    "grey-55": { label: "Grey 55%", description: "The bookmarked tick and dot at 55%: barely over rest." },
    "grey-70": {
      label: "Grey 70%",
      description: "The bookmarked tick and dot at 70%: a clear grey step over rest, under the lit band and hover.",
    },
    "dot-only": {
      label: "Dot only",
      description: "The bookmarked tick at rest (40%); only its dot, at 70%, marks it.",
    },
    full: { label: "Full", description: "The tick and dot at full opacity, as the rail drew them before." },
  },
  defaultArm: "grey-70",
});

/// Each arm's opacity for a bookmarked tick's bar and dot at rest (threadMinimap.css,
/// --acpmux-minimap-mark and --acpmux-minimap-mark-dot).
export const MARK_OPACITY: Record<keyof typeof threadMinimapMark.arms, { bar: number; dot: number }> = {
  "grey-55": { bar: 0.55, dot: 0.55 },
  "grey-70": { bar: 0.7, dot: 0.7 },
  "dot-only": { bar: 0.4, dot: 0.7 },
  full: { bar: 1, dot: 1 },
};
