// l10n-allow-file: sample transcript, not shipped UI.
// Every row kind that has buttons, at three text lengths: its buttons sit in their fixed slot, and
// none moves as the text grows or wraps (test/row-actions-slots-browser.test.ts compares the three).
// Leo, 2026-11-17, of a sent message's Copy right after its footer's words: "stop making the copy
// button move with the text, why was it not just at the right edge".
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

const TEXTS = {
  short: "Ship it.",
  long: "Use the cache directory for the retry state, not the system temp folder.",
  wrapped:
    "Use the cache directory for the retry state, not the system temp folder, and keep one file per session so two chats never share a backoff clock; then open the pull request and say what you measured before and after.",
} as const;

const snapshot = (text: string) =>
  chat(
    [
      user(text, 9, { id: "slot-sent" }),
      assistant(text, 8.5, { id: "slot-reply" }),
      summary(8.5, { id: "slot-reply-summary", status: "completed", durationMs: 34_000 }),
      row("user", 6, {
        id: "slot-received",
        text,
        untyped: true,
        incoming: { kind: "message", message: { name: "ci-lane", text, raw: text } },
      } as never),
      user(text, 1, {
        id: "slot-pending",
        pending: true,
        delivery: { state: "sending", promptId: "p-slot", sessionId: "s", sentAt: 0, slow: true },
      }),
    ],
    { isWorking: true },
  );

/// Shows every row's buttons, as the pointer over each row would, so one still holds them all.
const allShown: Play = async (ctx) => {
  const style = ctx.document.createElement("style");
  style.textContent = `.cv-user__actions, .cv-received__hover, .cv-received-actions, .cv-reply-actions,
    .cv-turn-actions, .cv-turn-time, .cv-message-footer-row > * { opacity: 1 !important; pointer-events: auto !important; }`;
  ctx.document.head.append(style);
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="slot-pending"] .cv-user__actions'));
};

export default agentPaneEntry({
  id: "agent-pane.row-actions-slots",
  title: "Row buttons keep their slot at any text length",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/conversation/UserBubble.tsx",
    "agent-session/acpmux/conversation/MessageActions.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  keywords: ["copy", "actions", "right edge", "footer", "slot"],
  variants: Object.fromEntries(
    (Object.keys(TEXTS) as (keyof typeof TEXTS)[]).map((length) => [
      length,
      {
        note: `${length} text: a sent and a still-sending prompt keep their buttons at the bubble's right edge, another agent's message keeps them at its line's end, and a reply's start at its prose's left edge.`,
        snapshot: snapshot(TEXTS[length]),
        play: allShown,
      },
    ]),
  ),
});
