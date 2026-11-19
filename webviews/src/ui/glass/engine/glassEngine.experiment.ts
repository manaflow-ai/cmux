// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The glass engine (engine/engineRenderer.ts): the lens's glass drawn as a refracting slab with a
/// pointer-lit rim, an adaptive veil and motion response, from a once-blurred still. Off ships. It
/// draws only where the lens draws (Debug > Liquid Glass: Lens, Spectrum or Glass Engine, a
/// wallpaper behind the page); the Debug choice Glass Engine turns it on without this key. To try
/// it in a pane, set `cmux.experiments` to `{"glass-engine":"on"}` in its web inspector and reload.
export const glassEngine = defineExperiment({
  id: "glass-engine",
  title: "Glass engine",
  description:
    "The lens's glass as a refracting slab: Snell refraction through a superellipse rim, a key light that follows the pointer, a Fresnel sheen, a veil that rises only where the wallpaper fights the text, and a flex when the glass moves. Compare the rim, the light and the text over the busy part of the wallpaper.",
  arms: {
    off: { label: "Lens", description: "The lens as it ships: quarter-circle bend, fixed rim light, fixed tint." },
    on: { label: "Engine", description: "The glass engine over the same still." },
  },
  defaultArm: "off",
});
