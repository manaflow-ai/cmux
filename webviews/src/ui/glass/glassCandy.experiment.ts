// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Glass candy (design/theming.md step 5; Leo 2026-11-04: "we don't have the candy yet"): looks for the
/// shared `.ui-glass` over the person's art, side by side for the UI judge (`ui-climb run
/// ui.glass-candy --exp glass-candy`). Gallery only: nothing in the app reads this yet.
export const glassCandy = defineExperiment({
  id: "glass-candy",
  title: "Glass candy",
  description:
    "The same glass card, composer and chip over the art, in four looks. Look at whether the art reads through the glass, whether the text on it stays easy to read, and whether the look is worth having.",
  arms: {
    plain: { label: "Plain", description: "The glass as it ships: the shared tint and blur, no refraction." },
    refraction: {
      label: "Refraction",
      description:
        "The lens with a thick rim and full gloss, a loupe that bends and magnifies the art and follows the pointer, and one light sheen across each glass on entry and on hover.",
    },
    depth: {
      label: "Depth",
      description:
        "Three layered glass panes at three depths: rising elevation, and a pointer parallax that moves the near pane most.",
    },
    "art-tint": {
      label: "Art tint",
      description:
        "The glass tint taken from the art's leading color, at the least alpha that keeps the text 4.5:1 over any part of the art.",
    },
  },
  defaultArm: "plain",
});
