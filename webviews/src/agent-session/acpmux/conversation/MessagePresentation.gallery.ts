// l10n-allow-file: synthetic gallery messages, never private transcripts.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, session, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SubagentFold } from "../subagents/subagentFold";

const report =
  "**Review passed.** Keep the message compact until someone opens it.\n\n- The queue keeps Edit, Delete and Send now.\n- `codex exec` inside a shell command is still a shell command.";
const received = user(report, 4, {
  id: "user-12",
  incoming: {
    kind: "message",
    message: { name: "review-host/pr-row", sessionId: "presentation-sender", text: report, raw: report },
  },
  untyped: true,
  steer: "waiting",
  steerPromptId: "presentation-steer",
});
const command = "reach review-host 'codex exec --sandbox read-only -m gpt-6-astra < prompt.txt'";
// Replay the same raw Bash metadata the identity fold receives. Command text alone cannot make
// a tracked agent row; a call the fold does not consume remains an ordinary tool call.
const fold = new SubagentFold();
fold.harness = "claude";
const update = {
  sessionUpdate: "tool_call",
  toolCallId: "presentation-review-command",
  title: "Bash",
  kind: "execute",
  status: "completed",
  rawInput: { command, description: "Run independent review" },
};
const consumed = fold.reduce({ seq: 1, at: minutesAgo(3), msg: { params: { update } } }, update);
const review = consumed
  ? fold.takeRows()
  : [
      activity(
        [
          tool("Bash", "execute", "completed", {
            command,
            description: "Run independent review",
            output: "reach: review-host -> worker-host\nReview completed: SHIP",
          }),
        ],
        3,
        { id: "presentation-shell" },
      ),
    ];
const sentBody = "## Review ready\n\n- **Queue actions** still work.\n- The report keeps `4d7bb4943641` readable.";
const recordedSend = activity(
  [
    tool("Bash", "execute", "completed", {
      command: `cat > /tmp/gallery-report.md <<'EOF'\n${sentBody}\nEOF`,
      description: "Write the report",
    }),
    tool("Bash", "execute", "completed", {
      command: "acpmux send --no-wait review-host/pr-row - < /tmp/gallery-report.md",
      description: "Send the report",
      output: "queued for delivery to review-host/pr-row",
    }),
  ],
  2,
  { id: "presentation-send" },
);
const snapshot = chat(
  [
    user("Review the queue and the transcript together.", 5),
    assistant("The independent review is ready; the next lane report can wait for this turn.", 4.5),
    summary(4.5, { status: "completed" }),
    received,
    ...review,
    recordedSend,
    assistant("Checking the last queued message…", 0.5, { streaming: true }),
  ],
  {
    title: "Message presentation",
    sessions: [
      session({ sessionId: "gallery-session", title: "Message presentation" }),
      session({
        sessionId: "presentation-sender",
        name: "review-host/pr-row",
        peer: "review-host",
        harness: "codex",
      }),
      session({ sessionId: "queue-lane-session", name: "queue-lane", harness: "claude" }),
    ],
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
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="user-12"] .cv-received__toggle'));
  await ctx.click({ selector: '[data-row-id="user-12"] .cv-received__toggle' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="user-12"] .cv-received__body'));
};
const openMessages: Play = async (ctx) => {
  await openReceived(ctx);
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="presentation-send"] .cv-sent'));
  await ctx.click({ selector: '[data-row-id="presentation-send"] .cv-sent' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="presentation-send"] .cv-md h2'));
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
    "meaning-expanded": {
      note: "One renderer in both directions: recorded file content opens as Markdown, with its shell command kept behind Raw. The review command stays Bash.",
      snapshot,
      play: openMessages,
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
