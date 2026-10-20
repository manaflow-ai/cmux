// l10n-allow-file: gallery fixtures (sample messages), not shipped UI.
// Another agent's message to this chat (IncomingMessageCard.tsx): its sender, the first two lines,
// and Reply (R with the card focused), which answers in place in the sender's chat and thread.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

const message = (text: string, minutes: number, fields: Partial<AcpmuxRow> = {}) =>
  user(text, minutes, {
    incoming: {
      kind: "message",
      message: { name: "Grid fix", sessionId: "child-3", msgId: "m-1", threadId: "t-1", text, raw: text },
    },
    ...fields,
  });

export default agentPaneEntry({
  id: "agent-pane.incoming-message",
  title: "Message from another agent",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/IncomingMessageCard.tsx"],
  anchors: [{ selector: ".cv-message.is-incoming" }],
  variants: {
    short: {
      note: "A one-line message from a chat here: Open beside, and Reply to answer in its thread.",
      snapshot: chat([
        user("Split the grid fix out to its own chat and tell me when tests pass", 9, { seq: 1 }),
        assistant("Started Grid fix; I'll hand back here when it reports.", 8.5),
        summary(8.5, { seq: 3, status: "completed" }),
        message("The grid fix is on cmux/grid-fix; tests pass.", 2, { seq: 4 }),
      ]),
    },
    long: {
      note: "A longer message folds to two lines; Reply stays on the card.",
      snapshot: chat([
        message(
          [
            "The grid fix is on cmux/grid-fix; tests pass.",
            "Two things to check before merging: the resize path now clamps to the last column,",
            "and the old snapshot test was updated, not deleted.",
            "Want me to open the PR?",
          ].join("\n"),
          2,
          { seq: 1 },
        ),
      ]),
    },
  },
});
