// l10n-allow-file: synthetic gallery messages, never private transcripts.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const report =
  "**Review passed.** Keep the message compact until someone opens it.\n\n- The queue keeps Edit, Delete and Send now.\n- `codex exec` inside a shell command is still a shell command.";
const received = user(report, 4, {
  id: "presentation-received",
  incoming: { kind: "message", message: { name: "sidebar-lane", text: report, raw: report } },
  untyped: true,
});
const command = "reach review-host 'codex exec --sandbox read-only -m gpt-6-astra < prompt.txt'";
const snapshot = chat(
  [
    user("Review the queue and the transcript together.", 5),
    assistant("The independent review is ready; the next lane report can wait for this turn.", 4.5),
    summary(4.5, { status: "completed" }),
    received,
    activity(
      [
        tool("Run independent review", "execute", "completed", {
          command,
          description: "Run independent review",
          output: "reach: review-host -> worker-host\nReview completed: SHIP",
        }),
      ],
      3,
    ),
    assistant("Checking the last queued message…", 0.5, { streaming: true }),
  ],
  {
    title: "Message presentation",
    isWorking: true,
    queue: [
      {
        id: "presentation-queued",
        prompt: "The layout checks passed. Read the compact report after this turn, then land the reviewed change.",
        message: {
          name: "queue-lane",
          sessionId: "queue-lane-session",
          text: "The layout checks passed. Read the compact report after this turn, then land the reviewed change.",
          raw: "The layout checks passed. Read the compact report after this turn, then land the reviewed change.",
        },
      },
    ],
  },
);

const openReceived: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="presentation-received"] .cv-received__toggle'));
  await ctx.click({ selector: '[data-row-id="presentation-received"] .cv-received__toggle' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="presentation-received"] .cv-received__body'));
};
const compare =
  (css: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".cv-received__queued"));
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
  };

export default agentPaneEntry({
  id: "agent-pane.message-presentation",
  title: "Compact received messages and quiet queued delivery",
  area: "Agent pane",
  height: 720,
  covers: [
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
  ],
  variants: {
    compact: {
      note: "Selected: one-line received messages; a plain delivery caption before in-flow hover actions. The shell command remains a normal tool row.",
      snapshot,
    },
    expanded: {
      note: "The selected strip opens to unboxed Markdown while the sender and actions keep their positions.",
      snapshot,
      play: openReceived,
    },
    "status-clock": {
      note: "Alternative: a clock adds a second visual signal to the same delivery caption.",
      snapshot,
      play: compare('.cv-received__queued::before { content: "◷"; margin-right: 4px; }'),
    },
    "status-pill": {
      note: "Alternative: a bordered delivery pill adds emphasis that the selected plain caption avoids.",
      snapshot,
      play: compare(
        ".cv-received__queued { padding-inline: 6px; border-radius: 8px; box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 25%, transparent); }",
      ),
    },
    "boxed-expanded": {
      note: "Comparison: the former filled card treatment around the same expanded message. The selected unboxed version uses less visual weight.",
      snapshot,
      play: async (ctx) => {
        await compare(
          ".cv-received__body { padding: 8px 12px; border-radius: 12px; background: color-mix(in srgb, var(--cv-text) 6%, transparent); box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 14%, transparent); }",
        )(ctx);
        await openReceived(ctx);
      },
    },
  },
});
