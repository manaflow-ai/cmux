// l10n-allow-file: gallery fixtures (sample messages and replies), not shipped UI.
// Another agent's message that `acpmux send` relayed from another machine: acpmux records only its
// client (`acpmux-peer#…`) and its text, which names its sender and this chat first
// ("summary-panel -> claude-sr2: …"). Each prompt here goes through the pane's own reading
// (incomingMessage.ts `incomingPrompt`, with this chat's name as direct.ts gives it), so the entry
// shows what the parser makes of the recorded text: the sender's card, and the person's own
// "foo -> bar:" left as their bubble.
import { agentPaneEntry } from "../../../gallery/format";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";

const CONFIRMED =
  "summary-panel -> claude-sr2: Confirmed. On feat-cmux-next today, the overlay card is as tall as its content and ends 15px under its last section (the body padding). Measured over the chat and with a diff in place, at 1400px and 900px tall: a 140px card each time. 560px / 80% is only a cap for content taller than that, and the body scrolls past it. Nothing stretches it, so no fix needed. The only full-height column is the opt-in Push placement setting; the default is overlay.";
const TYPED = "foo -> bar: rename the helper before the release branch is cut.";

/// A prompt as direct.ts reads a recorded `user_message` from `client` in the chat named claude-sr2.
function recorded(text: string, minutes: number, client: string) {
  const incoming = incomingPrompt(text, { client }, { isThisChat: (name) => name.toLowerCase() === "claude-sr2" });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: text, untyped: true })
    : user(text, minutes);
}

export default agentPaneEntry({
  id: "agent-pane.addressed-message",
  title: "Messages addressed sender first",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/IncomingMessageCard.tsx"],
  variants: {
    relayed: {
      note: "summary-panel's report, relayed from another machine as a steer, is its card: the chip, Markdown, no address line. The person's own arrow stays their bubble.",
      snapshot: chat(
        [
          user("Is the overlay card still stretching to the full height of the pane?", 9),
          assistant("Asked summary-panel to measure it on feat-cmux-next.", 8.5),
          recorded(CONFIRMED, 8, "acpmux-peer#01a161"),
          assistant("Confirmed by summary-panel: no fix needed.", 7.5),
          summary(7.5, { status: "completed" }),
          recorded(TYPED, 5, "acpmux-cli#01a2"),
          assistant("Renamed it.", 4.5),
          summary(4.5, { status: "completed" }),
        ],
        {
          title: "claude-sr2",
          sessions: [
            session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" }),
            session({ sessionId: "summary-panel-1", title: "summary-panel", name: "summary-panel" }),
          ],
        },
      ),
    },
  },
});
