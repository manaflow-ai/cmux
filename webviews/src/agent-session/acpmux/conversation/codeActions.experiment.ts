// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the corner buttons of a code card, an edit's diff, a tool's output and a reply table draw
/// (Leo 2026-11-07, on a code card's Wrap and Copy on opaque tiles with a gap: "why not just have it
/// similar to how we have the, you know, the copy button or whatever, where it doesn't really have
/// anything until you highlight over it"). Every arm draws each button as a reply's Copy does
/// (`.cv-iconbtn`): a bare glyph, and the hover fill on the button under the pointer only. Compare
/// them in the gallery's `agent-pane.code-toolbar-buttons`.
export const codeActionsLook = defineExperiment({
  id: "code-actions-look",
  title: "Code and output corner buttons",
  description:
    "How a code card's, a diff's, a tool output's and a table's corner buttons sit: bare glyphs side by side, spaced, shown only on the block's hover, or on a faint strip.",
  arms: {
    bare: {
      label: "Bare, touching",
      description:
        "Bare glyphs, buttons side by side as a reply's Copy row has them; the hovered one fills. Labeled headers keep them at rest.",
    },
    spaced: {
      label: "Bare, spaced",
      description: "Bare glyphs with the old 4px between the buttons.",
    },
    "block-hover": {
      label: "Bare, on hover",
      description:
        "Bare glyphs that show only while the pointer is on the block or focus is in it, labeled headers too.",
    },
    strip: {
      label: "Faint strip",
      description: "Bare buttons on one very faint shared strip, no solid tint.",
    },
  },
  defaultArm: "bare",
});
