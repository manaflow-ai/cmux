// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { MOTION_MS } from "../../../motion/scale.generated";

/// Session Info's segmented controls (Usage's Cost / Context sort, its first surface): how the
/// selection fill reaches the chosen option and how the panel under it swaps. Leo's reference (a game
/// character menu): "chunky pill tabs whose yellow highlight slides between them while the panel swaps,
/// the magenta brush-stroke wipe between views, bold dark cards". Today the fill jumps and the list
/// redraws in one frame, so Off stays the default; to try another, set `cmux.experiments` to
/// `{"selection-pill-travel":"spring","panel-swap-look":"brush","hover-fade":"fade"}` in the pane's
/// web inspector and reload. The selection, the list and every click change on the click in each arm;
/// only paint moves (ui/motion/SlidingIndicator.tsx, ViewSwap.tsx).
export const selectionPillTravel = defineExperiment({
  id: "selection-pill-travel",
  title: "Selection pill travel",
  description:
    "Session Info's segmented controls: whether the selection fill travels to the chosen option. Watch whether the eye follows the change and whether the fill ever lags a quick second click.",
  arms: {
    off: { label: "Off", description: "Today: each option fills itself in one frame." },
    spring: {
      label: "Spring",
      description: `One fill slides to the chosen option on the one spring (at its end by about 130 ms of ${MOTION_MS.large}, never past it).`,
    },
    stretch: {
      label: "Stretch",
      description: `The fill's leading edge reaches the chosen option first, then its trailing edge follows (${MOTION_MS.large} ms, no overshoot).`,
    },
    fade: {
      label: "Fade",
      description: `The fill fades out where it was and in on the chosen option, never travelling (${MOTION_MS.standard} ms).`,
    },
  },
  defaultArm: "off",
});

export type SelectionPillTravelArm = keyof typeof selectionPillTravel.arms;

export const panelSwapLook = defineExperiment({
  id: "panel-swap-look",
  title: "Panel swap",
  description:
    "The content under a segmented control when the choice changes (Usage's sorted list first). The new content is in place and clickable at once; watch whether the motion reads as one gesture with the pill.",
  arms: {
    off: { label: "Off", description: "Today: the new content is drawn in one frame." },
    fade: { label: "Crossfade", description: `The new content fades in over ${MOTION_MS.micro} ms.` },
    wipe: {
      label: "Edge wipe",
      description: `A slanted hard edge reveals it from the side it comes from over ${MOTION_MS.standard} ms.`,
    },
    brush: {
      label: "Brush stroke",
      description: `A soft mask paints it in from its side while an accent brush stroke rides the edge (${MOTION_MS.large} ms).`,
    },
  },
  defaultArm: "off",
});

export type PanelSwapLookArm = keyof typeof panelSwapLook.arms;

export const hoverFade = defineExperiment({
  id: "hover-fade",
  title: "Hover fade",
  description:
    "Session Info's segmented options on hover and press: how the hover ink comes and goes. A press changes only the fill (design/pressed-state.md) in every arm, with no flash.",
  arms: {
    off: { label: "Off", description: "Today: the hover ink changes in one frame." },
    fade: { label: "Fade", description: `Hover in and out over ${MOTION_MS.quick} ms.` },
    trail: {
      label: "Trail",
      description: `Hover in at once (it follows the pointer), out over ${MOTION_MS.micro} ms.`,
    },
    ease: {
      label: "Ease",
      description: `Hover in over ${MOTION_MS.quick} ms, out over ${MOTION_MS.standard} ms.`,
    },
  },
  defaultArm: "off",
});

export type HoverFadeArm = keyof typeof hoverFade.arms;
