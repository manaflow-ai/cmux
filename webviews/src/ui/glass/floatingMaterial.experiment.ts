// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/** One floating material (design-system-decisions B1; RFD 0207 "Floating material to B1"): B1 settles the
 * web's floating material as the theme surface at 88% in light and dark under blur 32 at saturate 1. The
 * web still frosts through the design scale's levels (popover 72/24, menu 80/32 (72 dark), chip 60/24, all
 * saturate 1.6; desktop.css). desktop.ts puts the arm on `<html>` as data-floating-material, and
 * desktop.css's FLOATING MATERIAL B1 block retunes the floating levels (popover, menu, chip and the
 * transient web tint) to B1 under `b1`; chrome, content, the lens and the fisheye stay. Off by default:
 * making B1 the default needs Leo's word. Compare in the gallery: `ui.glass-system`, variants `glass`
 * and `floating-b1`; to try it in a pane, set `cmux.experiments` to `{"floating-material":"b1"}` in its
 * web inspector and reload.
 * @status experimental
 */
export const floatingMaterial = defineExperiment({
  id: "floating-material",
  title: "Floating material",
  description:
    "The material every web floating surface (menus, popovers, the composer, hover cards, tooltips, dialogs) frosts with: today's glass levels, or B1's one floating material, 88% in light and dark, blur 32, saturate 1. Look for: legibility over busy text, and no green cast in light.",
  arms: {
    levels: {
      label: "Levels",
      description: "Today's levels: popover 72%/24, menu 80%/32 (72% in dark), chip 60%/24, each at saturate 1.6.",
    },
    b1: {
      label: "B1",
      description: "One floating material (B1): 88% in light and dark, blur 32, saturate 1, on every floating level.",
    },
  },
  defaultArm: "levels",
});

export type FloatingMaterial = keyof typeof floatingMaterial.arms;
