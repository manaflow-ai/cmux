// l10n-allow-file: gallery fixtures (sample prompts, replies and agent names), not shipped UI.
// The boundary between a finished turn and the next one that other agents' messages open (Leo,
// 2026-11-17, on a ~90px band under a reply's footer, then "Received 2 messages" over "Working for
// 15s" and a second "Received 2 messages" under it: "1 me 2 austin we sometimes have weird ui like
// this" / "in the periods here"). The chat Leo came back to: the "New since you looked" line sits
// at the turn boundary and is read, a turn that two messages opened runs, the agent reads them (an
// inbox notice, then each message on its own line) and loads a tool's schema (a hidden call).
// test/transcript-turn-boundary-gaps.test.ts measures every variant.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { received } from "../incomingFixture";
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { markUnreadRead } from "./unreadState";
import { minutesAgo } from "../../../gallery/clock";

const COORD = {
  id: "msg_5a0c1e7d9b2f4a6c8e0d1f3b5a7c9e1d",
  thread: "msg_5a0c1e7d9b2f4a6c8e0d1f3b5a7c9e1d",
  sender: "acp:0190a000-0000-7000-8000-0000000000c1",
  name: "claude-sr2-coord-old",
  body: "I picked up three items, each with a helper or reply: the land queue, the stuck screen-share jobs and the owners' table.",
};
const ARCH = {
  id: "msg_9e1d3b5a7c9f1e3d5b7a9c1e3f5d7b9a",
  thread: "msg_9e1d3b5a7c9f1e3d5b7a9c1e3f5d7b9a",
  sender: "acp:0190a000-0000-7000-8000-0000000000c2",
  name: "fable-screen-share-arch",
  body: "Update to the one-owner table, from the owners' replies.",
};

/// The divider's mark (`AcpmuxSince.key`), which the read variants mark read.
export const BOUNDARY_SINCE_KEY = "gallery-session:41";

/// The finished turn every variant starts with: a prompt, the reply and its footer row.
const finished: AcpmuxRow[] = [
  user("Where does the screen-share profile work stand?", 14, {
    id: "gap-prompt",
  }),
  assistant(
    "I sent the lane where the profile definitions live. I also corrected my earlier claim: my script only applied the network shaping.",
    13.5,
    { id: "gap-reply" },
  ),
  summary(13.5, { id: "gap-footer", status: "completed", durationMs: 31_000 }),
];

const divider = (): AcpmuxRow =>
  row(SINCE_DIVIDER, 13.4, {
    id: SINCE_DIVIDER,
    since: { key: BOUNDARY_SINCE_KEY, seq: 41, turns: 1 },
  });

/// The inbox notice that opened the turn: both messages, whole.
const notice = (minutes: number): AcpmuxRow =>
  user("", minutes, {
    id: "gap-inbox",
    untyped: true,
    incoming: {
      kind: "inbox",
      notice: {
        threads: [COORD, ARCH].map((message) => ({
          threadId: `from:${message.name}`,
          label: "",
          from: [message.name],
          count: 1,
          preview: message.body,
          blocker: false,
          promptIds: [message.id],
          messages: [{ from: message.name, text: message.body, promptId: message.id }],
        })),
      },
    },
  });

/// The agent's thought over the messages and a completed ToolSearch: discovery plumbing the
/// transcript hides (hiddenTools.ts). No work the run's line names.
const toolSearch = (minutes: number, id: string): AcpmuxRow =>
  activity(
    [
      thought("Two messages: the land queue and the owners' table. Loading the PR tools."),
      tool("ToolSearch", "other", "completed", {
        provenance: { claudeTool: "ToolSearch" },
        output: "loaded 2 tools",
      } as never),
    ],
    minutes,
    { id },
  );

const running = (minutes: number): AcpmuxRow =>
  activity(
    [
      tool("pr-owner --repo manaflow-ai/cmux who 44890 2>&1 | tail -4", "execute", "in_progress", {
        command: "pr-owner --repo manaflow-ai/cmux who 44890 2>&1 | tail -4",
      }),
    ],
    minutes,
    { id: "gap-running" },
  );

const working = (rows: AcpmuxRow[]) => {
  const base = chat(rows, { title: "Origin chores for product lanes" });
  return {
    ...base,
    isWorking: true,
    sessions: base.sessions.map((session) => ({
      ...session,
      status: "working" as const,
    })),
  };
};

/// Leo's first screenshot: the notice opens the turn, each message then comes into the running turn
/// on its own line, and the agent thinks, loads a tool's schema and runs a command.
export const inboxTurn = (withDivider: boolean): AcpmuxRow[] => [
  ...finished,
  ...(withDivider ? [divider()] : []),
  notice(1),
  { ...received("gap-coord", minutesAgo(0.95), COORD), continues: true },
  { ...received("gap-arch", minutesAgo(0.94), ARCH), continues: true },
  toolSearch(0.9, "gap-search"),
  running(0.5),
];

/// Leo's second screenshot: two messages open the turn, each on its own line, and it is thinking.
export const linesTurn = (withDivider: boolean): AcpmuxRow[] => [
  ...finished,
  ...(withDivider ? [divider()] : []),
  received("gap-coord", minutesAgo(1), COORD),
  received("gap-arch", minutesAgo(0.99), ARCH),
];

/// The message bodies each variant must name exactly once.
export const BOUNDARY_MESSAGES = [COORD.body, ARCH.body];

/// Marks the divider read, as reaching the latest message after seeing it does (unreadState.ts).
const readDivider: Play = async (ctx) => {
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-since, .cv-turn-actions")), { capMs: 10_000 });
  if (!ctx.document.querySelector(".cv-since")) return;
  markUnreadRead(BOUNDARY_SINCE_KEY);
  await ctx.waitFor(
    () => Boolean(ctx.document.querySelector(".cv-since[data-read]")) || !ctx.document.querySelector(".cv-since"),
    { capMs: 10_000 },
  );
};

const variant = (note: string, rows: AcpmuxRow[], play?: Play): AgentPaneVariant => ({
  note,
  snapshot: working(rows),
  ...(play && { play }),
});

export const BOUNDARY_VARIANTS = ["inbox-read", "lines-read", "inbox", "lines", "inbox-unread"] as const;

export default agentPaneEntry({
  id: "agent-pane.turn-boundary-gaps",
  title: "No blank band between turns",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/SinceDivider.tsx",
    "agent-session/acpmux/conversation/LaneNoticeBatch.tsx",
    "agent-session/acpmux/conversation/MessageRunLine.tsx",
  ],
  variants: {
    "inbox-read": variant(
      'Leo\'s first screenshot: a read "New since you looked" line at the boundary, a turn two messages opened, read and a hidden call.',
      inboxTurn(true),
      readDivider,
    ),
    "lines-read": variant(
      "Leo's second screenshot: a read divider, then two messages that opened a thinking turn.",
      linesTurn(true),
      readDivider,
    ),
    inbox: variant("The first, with no divider.", inboxTurn(false)),
    lines: variant("The second, with no divider.", linesTurn(false)),
    "inbox-unread": variant("The first, the divider not read yet: its line shows.", inboxTurn(true)),
  },
});
