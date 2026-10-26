// l10n-allow-file: synthetic gallery messages, never private transcripts.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const report = Array.from(
  { length: 12 },
  (_, i) => `- Step ${i + 1}: keep \`preview_token_${i}\` and #25141 readable. Check wrapping and paragraph gaps.`,
).join("\n\n");
const received = (text: string, minutes: number) =>
  user(text, minutes, {
    incoming: { kind: "message", message: { name: "preview-lane", text, raw: text } },
    untyped: true,
  });
const cards = chat([
  received(report, 3),
  received("Short report: the preview is readable.", 2),
  activity(
    [
      tool("SendMessage", "other", "completed", {
        inputSummary: JSON.stringify({ to: "preview-lane", message: report }),
      }),
    ],
    1,
  ),
]);

export default agentPaneEntry({
  id: "agent-pane.message-preview",
  title: "Agent message previews without bottom fades",
  area: "Agent pane",
  height: 720,
  covers: [
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/conversation/MessageCard.tsx",
  ],
  variants: {
    "one-line": {
      note: "Existing Minimal Mode: one line with an ellipsis; open to read the whole message.",
      snapshot: cards,
      display: { "sidebar.minimal": true },
    },
    "cards-no-fade": {
      note: "Today's received rows and actions, with whole-line previews instead of a bottom fade.",
      snapshot: cards,
    },
    "full-cards-no-fade": {
      checks: {
        layoutShiftMax: {
          value: 0.001,
          reason: "Opening the existing sent row turns its chevron; its SVG bounds shift slightly.",
        },
      },
      note: "Today's full cards, with intact lines and Show more instead of a bottom fade. Open the sent row to compare both directions.",
      snapshot: cards,
      play: async (ctx) => {
        if (!ctx.document.querySelector('.cv-message .cv-agentmsg__toggle[aria-expanded="true"]'))
          await ctx.click({ selector: ".cv-message .cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-message__text"));
      },
    },
  },
});
