// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// The switch in Settings > Advanced > Experiments (`experiments.hoverLook`, off by default) that
/// turns the restyled tooltips and hover cards on; experiments/switches.ts carries it to the page.
export const HOVER_LOOK_SWITCH = "hoverLook";

/// On `<html>` while the switch is on: the arm below. Every tooltip and hover card reads it
/// (ui/hoverLook.css). Absent, every hover surface is today's.
export const HOVER_LOOK_ATTRIBUTE = "data-hover-look";

/// The hover surfaces the restyle paints itself, off the App's glass (ui/glass/hostGlass.ts): a
/// Base UI tooltip and hover card, a title tooltip, a toolbar hint, a chart's tooltip (the same list
/// ui/hoverLook.css paints).
export const HOVER_LOOK_SURFACES = ".ui-tooltip, .ui-title-tooltip, .ui-hint, .ui-card, .cu-tooltip";

/// How tooltips and hover cards look once the switch is on (Leo, ask-68c2ce3e90: "i recall a lot of
/// our existing hovers and errors and whatnot look like shit"). Every arm is paint only: the
/// padding, type, rim width and so the size of every tooltip and card are today's, so turning it on
/// moves nothing. With the switch off no arm draws anything.
export const hoverLook = defineExperiment({
  id: "hover-look",
  title: "Tooltip and hover card look",
  description:
    "One look for every tooltip and hover card: the arms vary the glass's tint, its edge and its shadow; sizes never change.",
  arms: {
    crisp: {
      label: "Crisp",
      description:
        "A frostier glass with a crisp hairline ring, a lit top edge and a soft two-layer shadow; cards share it at a deeper shadow.",
    },
    ink: {
      label: "Ink",
      description:
        "Tooltips invert to an ink glass with the page color as their text, for the most contrast; hover cards keep Crisp's look.",
    },
    soft: {
      label: "Soft",
      description: "A clearer glass with a rounder corner, no ring and a wide diffuse shadow.",
    },
    one: {
      label: "One",
      description:
        "One material for every tooltip and hover card: the tooltip's contrast-fitted veil over the transient frost and the tooltip's corner, each blurring what it covers in place, one hover open at a time, shown and gone in one frame.",
    },
  },
  defaultArm: "crisp",
});

export type HoverLook = keyof typeof hoverLook.arms;

/// The arm that makes every hover surface one material and one at a time (Leo, 2026-11-22, softened:
/// "multiple styles for hover previews plus bad-looking translucency blur, unacceptable").
export const HOVER_LOOK_ONE: HoverLook = "one";
