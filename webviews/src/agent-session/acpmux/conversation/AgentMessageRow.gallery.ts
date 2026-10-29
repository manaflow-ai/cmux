// l10n-allow-file: gallery fixtures (sample messages between agents), not shipped UI.
// Messages between agents as the shared one-line row (AgentMessageRow.tsx): this agent's sends
// (MessageCard.tsx: Claude Code's SendMessage, acpmux_send, tell-coordinator, cmux send) collapsed
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

// Two background subagents, each sent a message by its agentId as Claude Code's SendMessage
// writes it (`to` and `recipient` both the id), and a third id whose Agent call is not in the
// loaded transcript: the first two read by their descriptions, the third as a short id, and each
// chip's tooltip holds the full id.
const REVIEW_ID = "a997582716e0ae335";
const UNNAMED_ID = "a5b7309ddf7afa44d";
const backgroundAgent = (id: string, name: string, agentId: string, minutes: number) => ({
  id: `gallery-session/${id}`,
  parent: null,
  name,
  task: name,
  kind: "general-purpose",
  state: "cancelled",
  startedAt: minutesAgo(minutes),
  endedAt: minutesAgo(minutes - 4),
  background: true,
  agentId,
});
const subagentSend = (to: string, message: string, summary: string) =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, recipient: to, recipient_kind: "agent", type: "message", summary, message }),
    output: JSON.stringify({ success: true, message: `Message queued for delivery to ${to} at its next tool round.` }),
  });
const subagentSends = () =>
  chat([
    user("Resume both subagents where they stopped.", 12),
    row(SUBAGENTS, 12, {
      subagents: [
        backgroundAgent("toolu_grid", "Fix grid jump", AGENT_ID, 12),
        backgroundAgent("toolu_review", "Review and merge the release notes PR", REVIEW_ID, 11.5),
      ],
    }),
    activity(
      [
        subagentSend(AGENT_ID, "Resume: carry on from where you stopped, then report in 5 lines.", "Resume grid fix"),
        subagentSend(REVIEW_ID, "Resume: finish the review and merge it (squash). Report in 3 lines.", "Resume review"),
        subagentSend(UNNAMED_ID, "Resume: rerun the pre-push check and report.", "Resume pre-push check"),
      ],
      2.9,
    ),
  ]);

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

// acpmux_send (acpmux_mcp.rs) as Claude Code and Codex name it: to a lane, and to a session on a peer.
const lanes = () =>
  chat([
    user("Ask lane-a to rebase, then tell the reviewer on build-box.", 3),
    activity(
      [
        tool("mcp__cmux__acpmux_send", "other", "completed", {
          inputSummary: JSON.stringify({
            to: "lane-a",
            text: "Rebase on feat-cmux-next.\nThen push and report the head.",
          }),
          output: "Sent to lane-a: steered into its running turn: it reads it at its next tool step (promptId 4f1c9e).",
        }),
      ],
      2.9,
    ),
    activity(
      [
        tool("cmux", "other", "completed", {
          inputSummary: JSON.stringify({
            server: "cmux",
            tool: "acpmux_send",
            arguments: { to: "build-box/reviewer", text: "#23377 is ready for review at dce64b66.", steer: false },
          }),
          output:
            "Sent to build-box/reviewer: queued behind its running turn: it reads it when that turn ends (promptId 81ab07).",
        }),
      ],
      2.8,
    ),
  ]);

const STOPPED_ID = "a5b7309ddf7afa44d";
const stoppedAgent = (minutes: number) =>
  row(SUBAGENTS, minutes, {
    subagents: [
      {
        id: "gallery-session/toolu_cap",
        parent: null,
        name: "Time-cap pre-push owner check",
        task: "Time-cap pre-push owner check",
        kind: "general-purpose",
        state: "cancelled",
        startedAt: minutesAgo(minutes),
        endedAt: minutesAgo(minutes - 1),
        agentId: STOPPED_ID,
      },
    ],
  });

// A coordinator's chat: one message delivered, one to an agent the person stopped, and a lane's
// message back.
const outcomes = () =>
  chat([
    user("Check on the pre-push lane and the grid lane", 6),
    gridAgent(6),
    stoppedAgent(6),
    activity(
      [
        sendMessage(
          AGENT_ID,
          "Rebase on the base branch, then rerun the grid tests.",
          "completed",
          JSON.stringify({ success: true, message: `Message delivered to ${AGENT_ID}.` }),
        ),
      ],
      4,
    ),
    activity(
      [
        sendMessage(
          STOPPED_ID,
          "Cap the owner check at 45 s and say so in the hook's output.",
          "completed",
          JSON.stringify({
            success: false,
            message: `Agent ${STOPPED_ID} was stopped by the user and won't be resumed.`,
          }),
        ),
      ],
      3.9,
    ),
    user("Grid fix is rebased; tests pass.", 2, {
      incoming: {
        kind: "message",
        message: {
          name: "grid-lane",
          sessionId: "child-4",
          text: "Grid fix is rebased; tests pass.",
          raw: "Grid fix is rebased; tests pass.",
        },
      },
      untyped: true,
    }),
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

const received = (name: string, text: string, minutes: number) =>
  user("", minutes, {
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
    untyped: true,
  });

const foldedRun = () =>
  chat([
    received("claude-sr2", "The coordinator has the green build.", 4),
    received("claude-sr2", "The exact head is 2a7ce36.", 3.8),
    received("claude-sr2", "I am checking the final screenshots now.", 3.6),
    received("claude-sr2", "I will report back when the review lands.", 3.4),
  ]);

const foldedMixedRun = () =>
  chat([
    received("claude-sr2", "The coordinator has the green build.", 4),
    received("codex-review", "Astra found no blocking findings.", 3.8),
    received("claude-sr2", "The exact head is 2a7ce36.", 3.6),
    received("codex-review", "The visual check is ready.", 3.4),
  ]);

export default agentPaneEntry({
  id: "agent-pane.agent-message-row",
  title: "Messages between agents",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/conversation/MessageCard.tsx",
    "agent-session/acpmux/conversation/agentMessages.ts",
  ],
  variants: {
    sent: {
      note: 'Sends start collapsed: an envelope, "Sent to" and the recipient as a chip (a subagent by its description, never its agentId), the first line muted, a chevron, and one muted word for how far it got: Queued, Delivered, Sent. A send still going out reads "Sending to" with the working mark.',
      snapshot: sends(),
    },
    lanes: {
      note: "acpmux_send to a lane and to a session on a peer (host/name), as Claude Code and Codex name the call: the same collapsed line, never an MCP row.",
      snapshot: lanes(),
    },
    "sent-subagents": {
      note: "Messages to subagents read by the subagent's description (the Agent call's), never its agentId; an id no Agent call in the loaded transcript names reads as a short id. Each chip's tooltip holds the full id.",
      snapshot: subagentSends(),
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
    outcomes: {
      note: "How each send ended, at its line's end: Delivered, muted; a send to an agent the person stopped reads Not delivered: agent stopped in a muted warning tone, never Sent. A lane's message back sits under them.",
      snapshot: outcomes(),
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
    "folded-run": {
      note: "Four consecutive messages fold to one quiet line naming claude-sr2; the message rows and their actions appear when opened.",
      snapshot: foldedRun(),
    },
    "folded-run-mixed": {
      note: "A consecutive burst from two agents folds to one count while retaining both sender names in the disclosure head.",
      snapshot: foldedMixedRun(),
    },
    "folded-run-opened": {
      note: "The folded burst opened: each received message keeps the shared compact row and its own full body.",
      snapshot: foldedRun(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-waiting__toggle" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-received").length >= 4);
      },
    },
  },
});
