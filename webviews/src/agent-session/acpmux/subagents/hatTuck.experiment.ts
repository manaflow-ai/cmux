// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the shown hat's tuck control looks and takes clicks (SubagentTray.tsx `onTuck`, subagents.css
/// "Tucking the hat away"). Leo, 2026-11-14, on the small chevron over the hat's top middle: "the tuck
/// away chevron clickability/visuals should be improved somehow". It used to be a bare 12px glyph cut
/// by the hat's top edge, its clicks only in an 8px band there. Every arm keeps the hover reveal (it
/// shows while the pointer is over the hat or it has keyboard focus) and the top-middle place, and
/// takes clicks in a box at least 24px tall; they differ in what is drawn. Compare them in the
/// gallery's `agent-pane.composer-hat-tuck`.
export const hatTuckLook = defineExperiment({
  id: "composer-hat-tuck",
  title: "Composer hat: tuck control",
  description:
    "The shown hat's tuck control at its top middle: a tab that hangs from the hat's top edge, a glass pill like the tucked hat's, or a band along the top edge that lights as a whole.",
  arms: {
    tab: {
      label: "Tab from the top edge",
      description:
        "A small tab hangs from the hat's top edge, the chevron in it, its surface faint while the hat is hovered, lit on hover, darker while pressed. Picked: it reads as part of the hat's edge, the same drawer-tab idea as the tucked pull tab, and its whole 40 by 24 box takes the click.",
    },
    pill: {
      label: "Glass pill",
      description:
        "The tucked hat's own glass pill (TrayPullTab.tsx), inside the hat just under its top edge, the chevron pointing down; lit on hover, pressed darker.",
    },
    band: {
      label: "Edge band",
      description:
        "The 96px band along the hat's top edge, now 24px tall, that lights as a whole on hover with the chevron in its middle.",
    },
  },
  defaultArm: "tab",
});
