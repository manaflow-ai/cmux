// l10n-allow-file: gallery fixtures (sample prompts, replies, lane names and messages), not shipped UI.
// Status, tool and message rows between prose (Leo, 2026-10-30: "see how claude code has those
// centered tool calls / id like more alignment too", and "1 CODEX 2 US 3 US 4 CODEX 5 CLAUDDE WE
// NEED TO LINE OUR SHIT UP LIKE THEIRS"). One live turn mixes the row kinds the way a long session
// does: a reply, a tool call, a reply, a subagent that finished, a reply, a background command that
// ended, a reply, another agent's message, a reply. The turns above it end with a "Worked for" line (a folded turn)
// and a footer that says its time and tokens beside the reply's action row. Every row's first ink
// sits on the prose's left edge, an icon's text one icon column in, and each status row sits in
// the middle of the gap between the replies around it (transcript-row-alignment.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, session, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";

const reviewer: Subagent = {
  id: "agent-docs-check",
  parent: null,
  name: "Check the docs agree",
  task: "Check the docs agree",
  state: "completed",
  startedAt: minutesAgo(9.7),
  endedAt: minutesAgo(9.3),
};

const received = (name: string, text: string, minutes: number) =>
  user("", minutes, {
    incoming: { kind: "message", message: { name, sessionId: `sub-${name}`, text, raw: text, harness: "codex" } },
    untyped: true,
  });

const rows = [
  // A turn with no tool work: its footer says how long it took and what it cost, beside the actions.
  user("Is the nightly feed current?", 20),
  assistant("Yes. The newest NEXT nightly is 12 minutes old and matches the branch tip.", 19.9),
  summary(19.9, {
    status: "completed",
    durationMs: 5_000,
    tokens: { output: 349, input: 220_600, cacheRead: 0, cacheWrite: 0 },
  }),
  // A turn with tool work: it folds behind its "Worked for" line.
  user("Check the release notes links.", 16),
  activity(
    [
      tool("git status", "execute", "completed", { command: "git status" }),
      tool("rg -n 'release-notes' docs", "execute", "completed", { command: "rg -n 'release-notes' docs" }),
    ],
    15.8,
  ),
  assistant("Every release notes link resolves; the 404 was a stale cache.", 15.5),
  summary(15.5, { status: "completed", durationMs: 10_000, toolCount: 2 }),
  // The live turn: replies with a status row between each pair.
  user("Review the release, check the docs and ask go-live for the feed.", 10),
  assistant("First the release commit.", 9.95),
  activity([tool("git log --oneline -1", "execute", "completed", { command: "git log --oneline -1" })], 9.9),
  assistant("I started a reviewer on the docs and kept the build running in the background.", 9.8),
  row(SUBAGENTS, 9.7, { subagents: [reviewer] }),
  assistant("The reviewer agrees with the docs except for the channel name.", 9.0),
  row("backgroundTask", 8.8, {
    backgroundTask: { toolCallId: "bg-build", command: "bun run build", state: "completed" },
  }),
  assistant("The background build finished cleanly.", 8.6),
  received("go-live", "The nightly is cut at 6d9ae71; the feed has it.", 8.4),
  assistant("go-live confirms the feed has the new nightly.", 8.2),
];

const base = chat(rows, { title: "Release check", isWorking: true });
const snapshot = {
  ...base,
  sessions: [
    ...base.sessions,
    session({
      sessionId: "sub-go-live",
      title: "Cut the nightly",
      name: "go-live",
      shortName: "go-live",
      harness: "codex",
    }),
  ],
};

/// The pointer on the first turn's footer, so its action row shows beside its time and tokens.
const revealFooter: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-turnSummary .cv-turn-summary") !== null);
  await ctx.hover({ selector: ".acpmux-turnSummary .cv-turn-summary" });
};

export default agentPaneEntry({
  id: "agent-pane.transcript-row-alignment",
  title: "Status, tool and message rows between replies",
  area: "Agent pane",
  height: 1120,
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx",
    "agent-session/acpmux/conversation/MessageActions.tsx",
    "agent-session/acpmux/conversation/BackgroundTaskNote.tsx",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  variants: {
    mix: {
      note: "A reply, a tool call, a reply, a subagent that finished, a reply, a background command that ended, a reply, another agent's message, a reply; above them a folded turn's Worked for line and a footer with its time, tokens and actions. Every row's first ink is on the prose's left edge, and each status row sits in the middle of the gap between the replies around it.",
      snapshot,
    },
    roomy: {
      note: "The same rows with the message gap kept under each reply's action row and as much under each status row: 38px on both sides.",
      snapshot,
      documentAttributes: { "transcript-status-gap": "roomy" },
    },
    off: {
      note: "The earlier rhythm: 38px over each status row and 8 under it, so the line hugs the reply below.",
      snapshot,
      documentAttributes: { "transcript-status-gap": "off" },
    },
    footer: {
      note: "The pointer on the first turn's footer: the copy glyph starts on the reply's left edge, as Codex and Claude draw it, and Worked for starts there too.",
      snapshot,
      play: revealFooter,
    },
  },
});
