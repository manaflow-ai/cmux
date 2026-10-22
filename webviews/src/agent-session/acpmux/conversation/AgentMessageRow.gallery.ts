// l10n-allow-file: gallery fixtures (sample messages between agents), not shipped UI.
// Messages between agents as the shared one-line row (AgentMessageRow.tsx): this agent's sends
// (MessageCard.tsx: Claude Code's SendMessage, tell-coordinator, cmux send) collapsed
// to "Sent to <name>", the message's first line and how far it got as one muted word (Sent,
// Queued, Delivered), never the send's raw result; the recipient a name, never a hex agentId.
// Opened, the message grows in place, capped near eight lines. A message another agent sent this
// chat (IncomingMessageCard.tsx) sits beside them.
import { minutesAgo } from "../../../gallery/clock";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { SUBAGENTS } from "../subagents/subagentFold";

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

// A subagent Claude Code started, with the agentId its Agent call answered; the SendMessage below
// names it by that id, and the row shows its description.
const AGENT_ID = "a39e817af38ddf5e7";
const gridAgent = (minutes: number) =>
  row(SUBAGENTS, minutes, {
    subagents: [
      {
        id: "gallery-session/toolu_grid",
        parent: null,
        name: "Fix grid jump",
        task: "Fix grid jump",
        kind: "general-purpose",
        state: "running",
        startedAt: minutesAgo(minutes),
        background: true,
        agentId: AGENT_ID,
      },
    ],
  });

const QUEUED = JSON.stringify({
  success: true,
  message: `Message queued for delivery to ${AGENT_ID} at its next tool round.`,
  pin: { id: "pin-1", at: 1 },
});

const LONG_NOTE = [
  "Rebase cmux/grid-fix on the base branch first.",
  "",
  "1. The image grid's jump comes from the placeholder height: reserve it from the image's",
  "   width and height attributes before the first paint.",
  "2. Keep the reserved box when the image fails, so the grid never collapses.",
  "3. Add a gallery state for a slow image and one for a broken one.",
  "4. Rerun the grid tests and the transcript tests.",
  "",
  "When both pass, send me the PR number and the head sha.",
  "If anything is red on base, name the check and the base sha instead of fixing it.",
].join("\n");

const sends = () =>
  chat([
    user("Tell release-rings-32 to merge, then let the coordinator know.", 3),
    gridAgent(3),
    activity([sendMessage(AGENT_ID, RELEASE_NOTE, "completed", QUEUED)], 2.95),
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

const long = () =>
  chat([
    user("Send the grid agent the plan", 3),
    gridAgent(3),
    activity([sendMessage(AGENT_ID, LONG_NOTE, "completed", QUEUED)], 2.9),
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
      note: 'Sends start collapsed: an envelope, "Sent to" and the recipient as a chip (a subagent by its description, never its agentId), the first line muted, a chevron, and one muted word for how far it got: Queued, Delivered, Sent. A send still going out reads "Sending to" with the working mark.',
      snapshot: sends(),
    },
    "sent-hover": {
      note: "Pointed at, a send shows Copy at the line's end, after its status word, clear of the line's words.",
      snapshot: sends(),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-message" });
      },
    },
    "sent-opened": {
      note: "Opened, the message grows in place under its line, with no box, and nothing else draws: no status block, no result JSON.",
      snapshot: sends(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-agentmsg__card"));
      },
    },
    "sent-opened-long": {
      note: "A long message opens capped near eight lines, the rest a scroll away under a fade.",
      snapshot: long(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-agentmsg__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-message__text"));
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
