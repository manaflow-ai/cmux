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
const codeReport = `\`\`\`ts\n${Array.from({ length: 32 }, (_, i) => `const preview_${i} = ${i};`).join("\n")}\n\`\`\``;

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
    "baseline-fade": {
      note: "Gallery-only reconstruction of the previous eight-line gradient clips, for before/after comparison.",
      snapshot: cards,
      play: async (ctx) => {
        const style = ctx.document.createElement("style");
        style.textContent = `
          .cv-received__body[data-cut] > .cv-received__text {
            max-height: calc(var(--cv-line-height) * 8) !important;
            -webkit-mask-image: linear-gradient(to bottom, currentColor calc(100% - var(--cv-line-height)), transparent);
            mask-image: linear-gradient(to bottom, currentColor calc(100% - var(--cv-line-height)), transparent);
          }
          .cv-received__show, .cv-message__more { display: none; }
          .cv-message__text {
            max-height: calc(8 * 20px) !important;
            overflow-y: auto;
            overscroll-behavior: contain;
          }
          .cv-message__text.is-cut {
            -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 28px), transparent);
            mask-image: linear-gradient(to bottom, #000 calc(100% - 28px), transparent);
          }
        `;
        ctx.document.head.append(style);
        await ctx.click({ selector: ".cv-message .cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-message__text"));
      },
    },
    "code-first": {
      note: "A tall code card is kept whole. Tab into its controls reveals the full message.",
      snapshot: chat([
        received(codeReport, 2),
        activity(
          [
            tool("SendMessage", "other", "completed", {
              inputSummary: JSON.stringify({ to: "preview-lane", message: codeReport }),
            }),
          ],
          1,
        ),
      ]),
    },
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
