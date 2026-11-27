// l10n-allow-file: gallery fixtures, not shipped UI.
// Leo 2026-10-26: "and i cant delete quote block text thingy with backspace? only shift enter? strange..."
import { agentPaneEntry } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.composer-quote",
  title: "Backspace out of a composer quote",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: ["agent-session/acpmux/MarkdownField.tsx"],
  variants: {
    text: {
      note: "Place the caret at the quote's start and press Backspace: its text becomes a plain paragraph.",
      ready: { draft: "> Keep this quote text" },
      snapshot: chat([]),
    },
    empty: {
      note: "Backspace removes an empty quote, leaving the composer ready for a plain paragraph.",
      ready: { draft: ">" },
      snapshot: chat([]),
    },
    "after-paragraph": {
      note: "Unwrapping a quote keeps the earlier paragraph separate and preserves both texts.",
      ready: { draft: "Earlier paragraph\n\n> Keep this quote text" },
      snapshot: chat([]),
    },
  },
});
