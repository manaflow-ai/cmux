// l10n-allow-file: synthetic transcript prose and equations for spacing comparison.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const reply = [
  "The first paragraph keeps the same prose rhythm at every density and interface scale.",
  "The second paragraph sits on the shared transcript grid, followed by a display equation.",
  "$$E=mc^2$$",
  "The closing paragraph confirms that the equation did not introduce a second fixed gap.",
  // Top-level blocks are spaced by the stack's gap; a list item's paragraphs carry the token, its math one grid gap.
  "- A list item with more to say.\n  Its paragraph leads into math.\n  $$a^2+b^2=c^2$$\n  And the item goes on after it.",
].join("\n\n");

// A stylesheet rule, not an inline style, so a transcript that re-renders after the play keeps it.
const setParagraphToken = (value: string) => async (ctx: PlayContext) => {
  const rule = ctx.document.createElement("style");
  rule.textContent = `.cv-md { --cv-para-after: ${value}; }`;
  ctx.document.head.append(rule);
};

export default agentPaneEntry({
  id: "agent-pane.paragraph-spacing-token",
  title: "Paragraph spacing token",
  area: "Agent pane",
  height: 620,
  covers: ["agent-session/acpmux/conversation/conversation.css"],
  variants: {
    before: {
      note: "Before: the math seam's 14px fallback made its margin derive from a separate fixed value.",
      snapshot: chat([user("Compare paragraph spacing around the equation.", 3), assistant(reply, 2)]),
      play: setParagraphToken("14px"),
    },
    shared: {
      note: "Chosen: prose and math use the scaled transcript inner-gap token.",
      snapshot: chat([user("Compare paragraph spacing around the equation.", 3), assistant(reply, 2)]),
    },
    roomy: {
      note: "Alternative: a wider token value, kept only for visual comparison against the chosen rhythm.",
      snapshot: chat([user("Compare paragraph spacing around the equation.", 3), assistant(reply, 2)]),
      play: setParagraphToken("16px"),
    },
  },
});
