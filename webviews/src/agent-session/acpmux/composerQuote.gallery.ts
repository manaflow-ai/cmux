// l10n-allow-file: gallery fixtures, not shipped UI.
// Leo 2026-10-26: "and i cant delete quote block text thingy with backspace? only shift enter? strange..."
import { agentPaneEntry } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.composer-quote",
  title: "Composer quotes stay at the bottom of the reply",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: [
    "agent-session/acpmux/Composer.tsx",
    "agent-session/acpmux/MarkdownField.tsx",
    "agent-session/acpmux/composerQuote.ts",
  ],
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
    bottom: {
      note: "Quote in Reply appends the selected text after the existing draft, with a quiet bar and blank line.",
      ready: { draft: "Reply text\n\n> Keep this quote text\n\n" },
      snapshot: chat([]),
    },
    stacked: {
      note: "Successive Quote in Reply actions keep their order at the bottom of the draft.",
      ready: { draft: "Reply text\n\n> First quote\n\n> Second quote\n\n" },
      snapshot: chat([]),
    },
  },
});
