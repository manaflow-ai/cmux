// l10n-allow-file: synthetic transcript prose and equations for spacing comparison.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const reply = [
  "The first paragraph keeps the same prose rhythm at every density and interface scale.",
  "The second paragraph sits on the shared transcript grid, followed by a display equation.",
  "$$E=mc^2$$",
  "The closing paragraph confirms that the equation did not introduce a second fixed gap.",
].join("\n\n");

const setParagraphToken = (value: string) => async (ctx: PlayContext) => {
  for (const element of ctx.document.querySelectorAll<HTMLElement>(".cv-md"))
    element.style.setProperty("--cv-para-after", value);
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
