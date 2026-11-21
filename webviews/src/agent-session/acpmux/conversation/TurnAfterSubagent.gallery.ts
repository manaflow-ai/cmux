// l10n-allow-file: gallery fixtures (prompts, a subagent's report and the agent's replies), not shipped UI.
// The main agent's turns after a subagent's "Subagent finished" row. Leo, 2026-11-08: "idk what
// happened here like the text in this situation isn't from the subagent?". A background command
// ended, then the subagent; its interim end and its later steps (acpmux weighs them silent, each
// with the subagent's call as origin) started three turns of the chat's own, with no prompt. Each
// reply went onto the subagent's line, joined into one muted block at the row's words, under its
// report open or closed (that look: agent-pane.subagent-done#reply-before). Now every reply is the
// agent's own turn (direct.ts `settleReaction`, `ownTurn`; Leo, 2026-11-09, on a one-line reply
// still folded in: "your response was weirdly folded into the rende?"): its rows
// at the reply column, the turn gap over its first row (transcriptGrid.ts MARK_OPENS_TURN) and a
// footer of its own (turns.ts `backgroundFooters`). The shipped variants replay acpmux's events
// through the pane's own client (fixtures/recording.ts), so they show what the code makes.
// References: claude/live/transcript-subagent-card-parent-text-attribution (Leo's capture),
// claude/live/transcript-copy-actions-per-message (a footer per reply), codex-mobile/live/grouped-
// activity-rows (a finished agent is one row, the agent's prose separate). Synthetic data.
// test/transcript-turn-after-subagent.test.ts measures the shipped variants in Chromium.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const TASK = "Fix nightly macOS build red";
/// The subagent's id and its Agent call, as the reducer names them.
export const AGENT = "fixer";
const CALL = `${AGENT}-call`;

const REPORT = `I opened PR #38915 into \`feat-cmux-next\`. The fleet tests pass. It is not merged.

- **Head SHA:** \`06b093467d76533b430de47b8a4532a2fe5f966a\`
- **Root cause:** no source commit broke the build. A cached toolchain image went stale, and the nightly picked it up.`;

/// The three turns of the agent's own the subagent's end and steps started, in order.
export const OWN_REPLIES = [
  "I started a re-review of #38357 at eb367413 and told the lane I'll send them the verdict.\n\nThis head fixes the BLOCK: when tokens are already configured, a peer starts the direct-link race right away instead of reading tokens over ssh first. Their tests pass.\n\nIt stays held until #38314 lands.",
  "Hourly pass done. Every unmet goal now has a live owner.\n\n19 lanes are running. One shows as stuck, retrying an inbox notice on attempt 3 of 4. Its PR has already merged, so it has no work left; I'm leaving it alone.",
  "#38812 got a BLOCK at 2b36cd7d. Its export now includes an action the Rust catalog doesn't have yet, which breaks the catalog's count check.\n\n#38888 already fixes that, so I'm landing it first.",
];

type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
const say = (text: string): [string, string, Record<string, unknown>] => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const subagent = (state: string): [string, string, Record<string, unknown>] => [
  "in",
  "subagent_spawned",
  {
    method: "session/update",
    params: {
      update: { sessionUpdate: "subagent_spawned" },
      _meta: {
        acpmux: {
          subagents: [
            {
              id: AGENT,
              parent: null,
              name: "general-purpose",
              task: TASK,
              state,
              toolCallId: CALL,
              ...(state === "completed" && { lastMessage: REPORT }),
            },
          ],
        },
      },
    },
  },
];
const ownTurn = (id: string, kind: string, text: string): [string, string, Record<string, unknown>][] => [
  [
    "mux",
    "background_turn",
    {
      state: "started",
      id,
      trigger: "task_notification",
      cause: { kind, status: kind === "subagent" ? "interim" : "completed", weight: "silent", origin: CALL },
    },
  ],
  say(text),
  ["mux", "background_turn", { state: "ended", id, trigger: "task_notification", quiet: false, reason: "result" }],
];

/// Leo's sequence, as acpmux records it: the person's turn starts the subagent; a background command
/// and then the subagent end after it; three notification-started turns follow.
export function turnAfterSubagentEvents(): Event[] {
  const steps: [string, string, Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Have a subagent fix the nightly macOS build red", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    subagent("running"),
    say("Started a subagent on it. I'll report when it's done."),
    ["mux", "turn_result", { turnId: "t1", status: "completed" }],
    [
      "in",
      "background_task_update",
      update({
        sessionUpdate: "background_task_update",
        taskId: "task-rerun",
        toolCallId: "rerun-call",
        command: "fleet unittest rerun for #38915",
        state: "completed",
      }),
    ],
    subagent("completed"),
    ...ownTurn("own-1", "subagent", OWN_REPLIES[0]!),
    ...ownTurn("own-2", "subagent_step", OWN_REPLIES[1]!),
    ...ownTurn("own-3", "subagent_step", OWN_REPLIES[2]!),
  ];
  const start = minutesAgo(30);
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: start + index * 60_000,
    dir,
    kind,
    msg,
  }));
}

const recording = {
  events: async () =>
    `${turnAfterSubagentEvents()
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
};

/// Opens the subagent's report, as Leo had it in his first capture.
export const openReport = async (ctx: PlayContext) => {
  const toggle = { selector: ".cv-subagent-report-row .cv-agentmsg__toggle" };
  await ctx.waitFor(() => ctx.document.querySelector(toggle.selector));
  await ctx.click(toggle);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-done__report") !== null);
};

const opening = { checks: { layoutShiftMax: { value: 0.8, reason: "Opening the report reveals it below its line." } } };

export default agentPaneEntry({
  id: "agent-pane.turn-after-subagent",
  title: "The agent's turns after a subagent's row",
  area: "Agent pane",
  height: 900,
  covers: ["agent-session/acpmux/direct.ts#settleReaction", "agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    "own-turn": {
      note: "Shipped: the report stays in the subagent's row; each of the agent's three turns is its own, at the reply column, the turn gap over it and its own footer under it.",
      snapshot: chat([]),
      recording,
    },
    "own-turn-open": {
      note: "Shipped, the report opened: the agent's first turn starts the turn gap under the report's card, never inside it.",
      snapshot: chat([]),
      recording,
      play: openReport,
      ...opening,
    },
    rule: {
      note: "Alternative: the same, with a hairline centred in the turn gap over each of the agent's own turns. It adds no height; it reads heavier than a prompt's boundary does.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "turn-boundary": "rule" },
    },
    "rule-open": {
      note: "Alternative, the report opened.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "turn-boundary": "rule" },
      play: openReport,
      ...opening,
    },
  },
});
