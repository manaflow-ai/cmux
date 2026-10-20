// l10n-allow-file: gallery fixtures (sample messages and replies), not shipped UI.
// Another agent's message to this chat as a card from it, and a Claude Code task notification as
// one quiet line (IncomingMessageCard.tsx, incomingMessage.ts). A message from a chat here also
// has Reply (R with the card focused), which answers in place in the sender's chat and thread.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const message = (
  name: string,
  text: string,
  raw = text,
  sessionId?: string,
  ids: { msgId?: string; threadId?: string } = {},
) => ({
  kind: "message" as const,
  message: { name, text, raw, ...(sessionId ? { sessionId } : {}), ...ids },
});

const gridFix = "The grid fix is on cmux/grid-fix; tests pass.";

export default agentPaneEntry({
  id: "agent-pane.incoming-message",
  title: "Messages from other agents",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/IncomingMessageCard.tsx"],
  variants: {
    messages: {
      note: "A chat here sends a short message (Open names it); a Claude Code session sends a long one, its envelope folded.",
      snapshot: chat([
        user("Split the grid fix into its own chat and report back", 9),
        assistant("Started Grid fix; it will message this chat when done.", 8.5),
        summary(8.5, { status: "completed" }),
        user(gridFix, 6, {
          incoming: message("Grid fix", gridFix, undefined, "child-3"),
          untyped: true,
        }),
        assistant("Merged cmux/grid-fix into this branch.", 5.5),
        summary(5.5, { status: "completed" }),
        user("Please review #123 and report back.", 4, {
          incoming: message(
            "leoli-fb",
            "Please review #123 and report back. The change touches the uploader's retry path, the queue's backoff and the settings page's copy, so check each one against its tests before you answer.",
            '<cross-session-message from="uds:/tmp/cc-socks/72618.sock" from-name="leoli-fb">\nPlease review #123 and report back.\n</cross-session-message>',
          ),
          untyped: true,
        }),
        assistant("Reviewing #123 now.", 3.5),
        summary(3.5, { status: "completed" }),
      ]),
    },
    reply: {
      note: "A message from a chat here, with its id and thread: Open beside, and Reply to answer in its thread.",
      snapshot: chat([
        user("Split the grid fix out to its own chat and tell me when tests pass", 9, { seq: 1 }),
        assistant("Started Grid fix; I'll hand back here when it reports.", 8.5),
        summary(8.5, { seq: 3, status: "completed" }),
        user(gridFix, 2, {
          seq: 4,
          incoming: message("Grid fix", gridFix, undefined, "child-3", { msgId: "m-1", threadId: "t-1" }),
          untyped: true,
        }),
      ]),
    },
    notice: {
      note: "A background task's end in an adopted Claude session's history: one quiet line, no raw XML.",
      snapshot: chat([
        user("Run the build in the background", 6),
        assistant("Started the build.", 5.5),
        summary(5.5, { status: "completed" }),
        user("Build finished", 3, { incoming: { kind: "notice", text: "Build finished" }, untyped: true }),
        assistant("The build passed.", 2.5),
        summary(2.5, { status: "completed" }),
      ]),
    },
  },
});
