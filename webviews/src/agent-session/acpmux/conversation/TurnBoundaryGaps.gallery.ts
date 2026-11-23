// l10n-allow-file: gallery fixtures (sample prompts, replies and agent names), not shipped UI.
// The boundary between a finished turn and the next one that other agents' messages open (Leo,
// 2026-11-17, on a ~90px band under a reply's footer, then "Received 2 messages" over "Working for
// 15s" and a second "Received 2 messages" under it: "1 me 2 austin we sometimes have weird ui like
// this" / "in the periods here"). The chat Leo came back to: the "New since you looked" line sits
// at the turn boundary and is read, a turn that two messages opened runs, the agent reads them (an
// inbox notice, then each message on its own line) and loads a tool's schema (a hidden call).
// The `woken-*` variants are Leo's 2026-11-22 screenshot: a reply's footer, ~40px of nothing, then
// "Received 2 messages" and "Working for 29s" ("sometimes you get these way-too-big gaps"). The
// notice came in while the turn before ran and opened the next one (`turn_started.carried`); acpmux
// said that turn runs before its record landed, so the client's typing placeholder sorted into the
// ended turn, under its footer (direct.ts). They hold that placeholder where the reducer left it.
// test/transcript-turn-boundary-gaps.test.ts measures every variant.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { received } from "../incomingFixture";
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";
import { sinceLook } from "./sinceLook.experiment";
import { SUBAGENT_STARTED } from "../subagents/subagentRows";
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

/// The inbox notice that opened the turn: both messages (or the ones named), whole.
const notice = (minutes: number, messages = [COORD, ARCH]): AcpmuxRow =>
  user("", minutes, {
    id: "gap-inbox",
    untyped: true,
    incoming: {
      kind: "inbox",
      notice: {
        threads: messages.map((message) => ({
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
    // As the client names the line's mark with its row (direct.ts snapshot `sinceKey`).
    ...(rows.some((row) => row.kind === SINCE_DIVIDER) && { sinceKey: BOUNDARY_SINCE_KEY }),
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

/// The client's typing placeholder (direct.ts) where the live reducer left it when acpmux said the
/// next turn runs before that turn's `turn_started` landed: after the ended turn's footer, before the
/// notice the record carried in.
const placeholder = (minutes: number): AcpmuxRow => row("typing", minutes, { id: "typing" });

/// Leo's 2026-11-22 screenshot: the notice the turn before did not read opens the next turn, with
/// the placeholder left under the footer, then the agent thinks and runs a command.
export const wokenTurn = (messages = [COORD, ARCH]): AcpmuxRow[] => [
  ...finished,
  placeholder(1.01),
  notice(1, messages),
  toolSearch(0.9, "gap-search"),
  running(0.5),
];

/// The same with the messages on their own lines, the turn still thinking.
export const wokenLines = (): AcpmuxRow[] => [
  ...finished,
  placeholder(1.01),
  ...linesTurn(false).slice(finished.length),
];

/// Leo's 2026-11-22 screenshot: the reader came back while a turn ran, and all it wrote since was a
/// subagent's "started working" line (acpmux counts a running turn's write as unread). Nothing new to
/// read: no line (sinceNews.ts).
export const statusTurn = (withDivider: boolean): AcpmuxRow[] => [
  ...finished,
  ...(withDivider ? [divider()] : []),
  {
    id: "gap-subagent",
    version: 1,
    kind: SUBAGENT_STARTED,
    at: minutesAgo(0.6),
    subagents: [
      {
        id: "gap-subagent-1",
        parent: null,
        name: "Pool VMs nodiscard remount",
        task: "Remount the pool VMs' scratch disks without discard",
        state: "running",
        startedAt: minutesAgo(0.6),
      },
    ],
  },
];

/// The message bodies each variant must name exactly once.
export const BOUNDARY_MESSAGES = [COORD.body, ARCH.body];

/// Marks the divider read, as reaching the latest message after seeing it does (unreadState.ts).
const readDivider: Play = async (ctx) => {
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-since, .cv-turn-actions")), { capMs: 10_000 });
  if (!ctx.document.querySelector(".cv-since")) return;
  markUnreadRead(BOUNDARY_SINCE_KEY);
  await ctx.waitFor(
    () =>
      Boolean(ctx.document.querySelector(".cv-since:not([data-shown])")) || !ctx.document.querySelector(".cv-since"),
    { capMs: 10_000 },
  );
};

const variant = (note: string, rows: AcpmuxRow[], play?: Play): AgentPaneVariant => ({
  note,
  snapshot: working(rows),
  ...(play && { play }),
});

export const BOUNDARY_VARIANTS = [
  "inbox-read",
  "lines-read",
  "inbox",
  "lines",
  "inbox-unread",
  "status-unread",
  "status",
  "woken-inbox",
  "woken-one",
  "woken-lines",
] as const;

/// How many of BOUNDARY_MESSAGES a variant names: all but `woken-one`, whose notice holds one.
export const boundaryNamed = (variant: string) => (variant === "woken-one" ? 1 : BOUNDARY_MESSAGES.length);

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
  // How the line looks (sinceLook.experiment.ts): A a thin hairline, B on the Worked for rule
  // (shipped), C a New pill alone. None takes height, so reading it moves no row in any arm.
  experiment: {
    definition: sinceLook,
    script: [{ name: "Mark the line read", run: readDivider }],
  },
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
    "inbox-unread": variant(
      "The first, the divider not read yet: its line shows, over the gap, taking no height.",
      inboxTurn(true),
    ),
    "status-unread": variant(
      "Leo's 2026-11-22 screenshot: unread, but all that came is a subagent's \"started working\" line: no line.",
      statusTurn(true),
    ),
    status: variant("The same with no divider: the rows sit exactly here.", statusTurn(false)),
    "woken-inbox": variant(
      "Leo's 2026-11-22 screenshot: a notice the turn before never read opens the next turn; the typing placeholder sits under the footer.",
      wokenTurn(),
    ),
    "woken-one": variant("The same with one message.", wokenTurn([COORD])),
    "woken-lines": variant("The same with the messages on their own lines, the turn thinking.", wokenLines()),
  },
});
