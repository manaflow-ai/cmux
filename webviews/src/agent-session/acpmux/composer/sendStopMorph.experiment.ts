// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the composer's one send slot turns from Send into Stop when a turn starts, and back when it
/// ends (Leo, 2026-11-07: "At the very least, like the Enter to the Stop button, I like. I think it
/// would be cool. You know, a fast animation"). Every arm keeps the button's 28 px box, runs once in
/// the motion scale's 180 ms step, and swaps at once under Reduce Motion. Gallery
/// `agent-pane.composer-send-stop-morph`.
export const sendStopMorph = defineExperiment({
  id: "send-stop-morph",
  title: "Send and Stop morph",
  description:
    "The glyph change in the composer's send slot when a turn starts or ends. The button itself never moves or resizes; only its glyph changes.",
  arms: {
    scale: {
      label: "Crossfade + scale",
      description: "The old glyph shrinks to 70% as it fades; the new one grows from 70% as it fades in.",
    },
    rotate: {
      label: "Rotate",
      description: "The crossfade and scale, with the old glyph turning out a quarter turn and the new one turning in.",
    },
    path: {
      label: "Path morph",
      description: "One stroke bends from the old glyph's outline into the new one's.",
    },
    blur: {
      label: "Blur crossfade",
      description: "The old glyph blurs out as the new one comes into focus.",
    },
  },
  defaultArm: "scale",
});

export type SendStopMorphArm = keyof typeof sendStopMorph.arms;
