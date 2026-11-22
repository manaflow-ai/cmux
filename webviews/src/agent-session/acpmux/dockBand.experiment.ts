// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";
import type { DockBandArm } from "./conversation/besideStack";

/// How much of the transcript shows at the foot of the floating bottom stack: under the composer
/// card and in the quiet row's band under it (conversation/besideStack.ts, the transcript's mask
/// layers; conversation.css `--acpmux-beside-*`). Leo, 2026-11-22, scrolled up in a chat: "AND I
/// KINDA HATE HOW MUCH FUCKING SOLID + BLUR THERE IS AT THE BOTTOM [image] OF THE BOX. FIGURE OUT HOW
/// WE CAN HAVE MORE STUFF THERE. [...] WE DO WANT SOME BLUR BUT... IDK FIGURE OUT HOW TO ELIMINATE
/// THAT BOTOM BULLSHIT". Every arm keeps the one glass material: the only blur is the card's own
/// glass (composerStates.css), never a band of its own, so the rows run under the card only where
/// that glass blurs (a see-through window, Lens, Spectrum); an opaque window's card and Reduce
/// Transparency blur nothing, and keep the shipped band (conversation/useBesideStack.ts).
/// Measured (test/agent-pane-dock-band.test.ts, 760 x 640 pane, Default density, one-line card 48 px,
/// quiet row band 40 px under it): 0 px of rows from the card's top to the pane's bottom shipped;
/// ~44-46 px under the card with `frost`; +13.5 px under it with `frost-ramp`; +28 px with
/// `frost-through`, where the rows run behind the quiet row's labels. A fourth arm, the card's
/// footprint only (rows in the gutters beside it), showed 0 px more: rows never reach the gutters.
/// Not shipped yet: in Chromium the rows under the card read nearly sharp through the prompt (stills
/// 2026-11-22), so the card's glass does not frost them; the arms wait on a frost that does.
/// Compare in the gallery's `agent-pane.dock-band`, or set `cmux.experiments` to
/// `{"dock-band":"frost-ramp"}` in the pane's web inspector and reload.
export const dockBand = defineExperiment({
  id: "dock-band",
  title: "The band at the bottom of the chat, behind the composer",
  description:
    "A long chat scrolled up, so rows run behind the composer. Look at how much of the transcript reads at the pane's foot, whether the prompt and the quiet row stay legible, and whether the card still reads as glass.",
  arms: {
    shipped: {
      label: "Shipped (before)",
      description:
        "The rows stop at the card's top edge across the pane: the card's glass frosts nothing and the quiet row's band under it is blank.",
    },
    frost: {
      label: "Frost under the card",
      description:
        "The rows run on under the card, frosted by its own glass, and stop at its bottom edge; the quiet row's band stays blank.",
    },
    "frost-ramp": {
      label: "Frost, short ramp",
      description:
        "The rows run under the card's glass, then fade out over 16 px past its bottom edge; blank only under the quiet row's text.",
    },
    "frost-through": {
      label: "Frost, no band",
      description:
        "No blank band at all: the rows run under the card's glass and on to the pane's bottom edge, fading out behind the quiet row.",
    },
  } satisfies Record<DockBandArm, { label: string; description: string }>,
  defaultArm: "shipped",
});
