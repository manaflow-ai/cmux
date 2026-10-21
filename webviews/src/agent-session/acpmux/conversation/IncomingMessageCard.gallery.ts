// l10n-allow-file: gallery fixtures (sample messages and replies), not shipped UI.
// Another agent's message to this chat as a card from it, and a Claude Code task notification as
// one quiet line (IncomingMessageCard.tsx, incomingMessage.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const message = (name: string, text: string, raw = text, sessionId?: string) => ({
  kind: "message" as const,
  message: { name, text, raw, ...(sessionId ? { sessionId } : {}) },
});

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
        user("The grid fix is on cmux/grid-fix; tests pass.", 6, {
          incoming: message("Grid fix", "The grid fix is on cmux/grid-fix; tests pass.", undefined, "child-3"),
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
