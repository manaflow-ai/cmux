// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the shown hat's tuck control looks (SubagentTray.tsx `onTuck`, subagents.css "Tucking the hat
/// away"). Leo, 2026-11-14, on the small chevron over the hat's top middle: "the tuck away chevron
/// clickability/visuals should be improved somehow". It used to be a bare 12px glyph cut by the hat's
/// top edge, its clicks only in an 8px band there. Every arm keeps the hover reveal (it shows while the
/// pointer is over the hat or it has keyboard focus), the top-middle place and one click box (96 by
/// 12px from the edge, stopping above the header's centre line so a click there still opens the hat);
/// they differ in what is drawn. Compare them in the gallery's `agent-pane.composer-hat-tuck`.
export const hatTuckLook = defineExperiment({
  id: "composer-hat-tuck",
  title: "Composer hat: tuck control",
  description:
    "The shown hat's tuck control at its top middle: a tab that hangs from the hat's top edge, a glass pill like the tucked hat's, or a band along the top edge that lights as a whole.",
  arms: {
    tab: {
      label: "Tab from the top edge",
      description:
        "A small tab hangs from the hat's top edge, the chevron in it, its surface faint once revealed, lit on hover anywhere in the click box, darker while pressed. Picked: it reads as part of the hat's edge, the same drawer-tab idea as the tucked pull tab.",
    },
    pill: {
      label: "Glass pill",
      description:
        "The tucked hat's own glass pill (TrayPullTab.tsx) on the hat's top edge, the chevron pointing down; lit on hover, pressed darker.",
    },
    band: {
      label: "Edge band",
      description: "The whole 96px click box along the hat's top edge lights on hover, the chevron in its middle.",
    },
  },
  defaultArm: "tab",
});
