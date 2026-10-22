// l10n-allow-file: gallery fixtures (sample messages between agents), not shipped UI.
// Messages between agents as the shared one-line row (AgentMessageRow.tsx): this agent's sends
// (MessageCard.tsx: Claude Code's SendMessage, tell-coordinator, cmux send) collapsed to "Sent to
// <name>" and the message's first line, opened to the whole message and how far it got; and a
// message another agent sent this chat (IncomingMessageCard.tsx) beside them.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const RELEASE_NOTE = [
  "#23377: go. Add risk:human-ok at dce64b66 and merge it now.",
  "The standing order is that a risk:high PR with SHIP at its exact head lands without asking.",
  "Report the merged number when it is in.",
].join(" ");

const sendMessage = (to: string, message: string, status = "completed", output?: string) =>
  tool("SendMessage", "other", status, {
    inputSummary: JSON.stringify({ to, message }),
    ...(output ? { output } : {}),
  });

const sends = () =>
  chat([
    user("Tell release-rings-32 to merge, then let the coordinator know.", 3),
    activity(
      [sendMessage("release-rings-32", RELEASE_NOTE, "completed", "delivered to release-rings-32 (id 9defc4d0ed87)\n")],
      2.9,
    ),
    activity(
      [
        tool("Run", "execute", "completed", {
          command: 'tell-coordinator "release-rings: #23377 merging now\\nnext: the nightly cut"',
          output: "",
        }),
      ],
      2.8,
    ),
    activity(
      [
        tool("Run", "execute", "in_progress", {
          command: 'cmux send --surface reviewer "CI green on #23377, merging"',
        }),
      ],
      2.7,
    ),
  ]);

const both = () =>
  chat([
    user("Split the grid fix into its own chat and report back", 9),
    // No turn summary after the send: a finished turn folds its rows under Worked for.
    activity([sendMessage("grid-fix", "Fix the image grid's jump on load; report back here when tests pass.")], 8.8),
    user("The grid fix is on cmux/grid-fix; tests pass.", 6, {
      incoming: {
        kind: "message",
        message: {
          name: "grid-fix",
          sessionId: "child-3",
          text: "The grid fix is on cmux/grid-fix; tests pass.\n\nThe grid now reserves its height before the images load.",
          raw: "The grid fix is on cmux/grid-fix; tests pass.\n\nThe grid now reserves its height before the images load.",
        },
      },
      untyped: true,
    }),
    assistant("Merged cmux/grid-fix into this branch.", 5.5),
    summary(5.5, { status: "completed" }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.agent-message-row",
  title: "Messages between agents",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/conversation/MessageCard.tsx",
  ],
  variants: {
    sent: {
      note: 'Sends start collapsed: an envelope, "Sent to" and the recipient as a chip, the first line muted, a chevron. A send still going out reads "Sending to" with the working mark.',
      snapshot: sends(),
    },
    "sent-opened": {
      note: "Opened, a send shows the whole message in a glass card, then how far it got (Delivered to …, without the receipt's id) and how it went out.",
      snapshot: sends(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-agentmsg__card"));
      },
    },
    "both-directions": {
      note: "A message this agent sent and the answer another agent sent back, one line each at the transcript's left.",
      snapshot: both(),
    },
    "both-directions-opened": {
      note: "Both opened: the sent message and the received one under their lines.",
      snapshot: both(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-agentmsg__card"));
        await ctx.click({ selector: ".cv-received__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-received__body"));
      },
    },
  },
});
