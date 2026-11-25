// l10n-allow-file: gallery fixtures (a prompt and the agent's notes and reply), not shipped UI.
// "Worked for" over work the agent started on its own. Leo, 2026-11-10: "too much space in between
// here", on an open "Worked for 1m 6s · 1 tool call" with an empty band between its rule and the
// fold's first row. A background task's notification started the turn, so the first row under the
// header took the turn gap (transcriptGrid.ts MARK_OPENS_TURN) on top of the room the header keeps
// under its rule. The header opens the turn: the row under it opens nothing (model.ts
// `opensBackgroundTurn`). The variants replay acpmux's events through the pane's own client
// (fixtures/recording.ts), so they show what the code makes. Synthetic data.
// test/agent-pane-background-turns.test.ts holds the gap at 0 in the model.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const CHAT = "0190a000-0000-7000-8000-0000000000f3";

type Step = [string, string, Record<string, unknown>];
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const think = (text: string): Step => [
  "in",
  "agent_thought_chunk",
  update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
];
const ran = (id: string, title: string): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", status: "completed" }),
];

/// A person's turn, then a turn a finished background task started: two notes around one command,
/// then the reply.
export function workedOverBackgroundEvents(): Event[] {
  const steps: Step[] = [
    ["mux", "user_message", { text: "Land it once both runs pass", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    say("Both runs are queued. I'll land it when they pass."),
    ["mux", "turn_result", { turnId: "t1", status: "completed" }],
    ["mux", "background_turn", { state: "started", id: "bg", trigger: "task_notification" }],
    [
      "mux",
      "user_message",
      { text: "<task-notification><summary>Background command finished</summary></task-notification>", turnId: "t2" },
    ],
    ["mux", "turn_started", { turnId: "t2" }],
    think(
      "I'm checking whether the gate accepts the marker, and I'll look through the hooks to see where it's handled.",
    ),
    ran("gate", "Check how the gate reads Compiled lines"),
    think("The gate accepts the result, so I'm waiting on the waiter, which stops at DONE."),
    say(
      "The gate accepts the marker. Both runs are still queued. When the waiter reports, I will check the two tests in each run, then land.",
    ),
    ["mux", "turn_result", { turnId: "t2", status: "completed" }],
    [
      "mux",
      "background_turn",
      { state: "ended", id: "bg", trigger: "task_notification", quiet: false, reason: "result" },
    ],
  ];
  const start = minutesAgo(30);
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: start + index * 6_000,
    dir,
    kind,
    msg,
  }));
}

const recording = {
  events: async () =>
    `${workedOverBackgroundEvents()
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
};

/// Opens the fold, as Leo had it in his capture.
export const openFold = async (ctx: PlayContext) => {
  const toggle = { selector: "button.cv-worked.is-toggle" };
  await ctx.waitFor(() => ctx.document.querySelector(toggle.selector));
  await ctx.click(toggle);
  await ctx.waitFor(() => ctx.document.querySelector(`${toggle.selector}[aria-expanded="true"]`) !== null);
};

export default agentPaneEntry({
  id: "agent-pane.worked-over-background",
  title: '"Worked for" over work the agent started on its own',
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/model.ts#opensBackgroundTurn", "agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    closed: {
      note: 'Shipped, the fold shut: the reply sits right under the header\'s rule, as under any "Worked for".',
      snapshot: chat([]),
      recording,
    },
    open: {
      note: "Shipped, the fold open: the first step sits right under the rule, on the rows' own pitch, with no turn gap between.",
      snapshot: chat([]),
      recording,
      play: openFold,
      checks: { layoutShiftMax: { value: 0.8, reason: "Opening the fold reveals its rows below the header." } },
    },
  },
});
