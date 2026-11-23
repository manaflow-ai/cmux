// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the composer's controls read: +, the harness and model picker, the mic and Send
/// (composerClimbs.css, `data-footer-controls` on the composer). Leo dislikes capsule pills: every
/// arm uses small-radius rects or plain text, and a round control is a true circle. Gallery
/// `agent-pane.composer`; the default arm is the shipped row.
export const composerFooterControls = defineExperiment({
  id: "composer-footer-controls",
  title: "Composer controls",
  description: "The controls row: how the model picker, +, the mic and Send read.",
  arms: {
    shipped: {
      label: "Shipped",
      description: "Plain line glyphs for +, mic and Send, the model as quiet text under the box, as it ships.",
    },
    chips: {
      label: "Text chips",
      description:
        "The model and mode as text chips with a chevron on a faint control-cornered rect, + and mic as icons, Send a solid accent circle.",
    },
    segment: {
      label: "Grouped segment",
      description:
        "+, mic and Send grouped into one bordered segment at the control corner with hairline dividers; the model stays text.",
    },
    bold: {
      label: "Codex disc",
      description:
        "Larger 32 px controls: + on a round soft disc, the model in primary ink, Send a filled text-color circle with a dark arrow.",
    },
  },
  defaultArm: "shipped",
});

export type ComposerFooterControlsArm = keyof typeof composerFooterControls.arms;
