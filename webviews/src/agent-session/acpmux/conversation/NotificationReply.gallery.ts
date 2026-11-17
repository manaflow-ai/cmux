// l10n-allow-file: gallery fixtures (prompts, a subagent's report and the agent's replies), not shipped UI.
// A notification row ("Subagent finished", a background command's end) and the agent's own reply
// that came right after it. Leo, 2026-11-09 20:33Z: "these rendered previews dont have time... maybe
// they dont have other things too / and your response was weirdly folded into the rende?". His
// capture: "Subagent finished: <Why no nightly since 16:36Z> No, it isn't the latest. Nothing has
// published since 0d… › ● 9m 39s"; opened, the report's card and no time; and the agent's next words
// ("Nothing new here: …") drawn inside that row, muted and indented, open or shut. The turn's own text
// now always draws as the agent's own message under the row (direct.ts `settleReaction`), and the
// opened row keeps every field the shut one has: its mark, its new dot, its time, its chevron and its
// name chip that opens the subagent (AgentMessageRow.tsx). The shipped variants replay acpmux's
// events through the pane's own client (fixtures/recording.ts), so they show what the code makes.
// The before look is agent-pane.subagent-done#reply-before. test/notification-reply-browser.test.ts
// measures these in Chromium. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const CHAT = "0190a000-0000-7000-8000-0000000000e9";
export const TASK = "Why no nightly since 16:36Z";
export const AGENT = "nightly-why";
const CALL = `${AGENT}-call`;
const SHELL = "nightly-lookup";
export const REPORT =
  "No, it isn't the latest. Nothing has published since 0d4e2a1: the 18:00Z nightly stopped at its notarize step and the 19:00Z one was never queued.";
/// The agent's own reply to the subagent's end: one short quiet line, the kind that used to fold.
export const REPLY =
  "Nothing new here: that was the nightly helper's last background lookup finishing, which I already reported.";
/// The agent's own reply to a background command's end.
export const COMMAND_REPLY = "The lookup finished: still no nightly after 16:36Z.";

type Step = [string, string, Record<string, unknown>];
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const subagent = (state: string): Step => [
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
              ...(state === "completed" && { result: REPORT }),
            },
          ],
        },
      },
    },
  },
];
/// A turn the agent ran on its own because a task ended: acpmux weighs it a result of `origin`.
const notified = (id: string, kind: string, origin: string, reply: string | undefined): Step[] => [
  [
    "mux",
    "background_turn",
    {
      state: "started",
      id,
      trigger: "task_notification",
      cause: { kind, status: "completed", weight: "result", origin },
    },
  ],
  ...(reply === undefined ? [] : [say(reply)]),
  ["mux", "background_turn", { state: "ended", id, trigger: "task_notification", quiet: true, reason: "result" }],
];

const prompt: Step[] = [
  ["mux", "user_message", { text: "Is the nightly I'm on the latest?", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  subagent("running"),
  say("I started a subagent to check the nightly feed."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
];

const commandPrompt: Step[] = [
  ["mux", "user_message", { text: "Look up the last nightly in the background", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: SHELL,
      title: "gh run list --workflow nightly",
      kind: "execute",
      status: "completed",
      rawInput: { command: "gh run list --workflow nightly", run_in_background: true },
    }),
  ],
  say("Started the lookup."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
];

function events(steps: Step[]): Event[] {
  const start = minutesAgo(20);
  // The subagent ran 9m 39s, as in Leo's capture: its end is 579 s after its start.
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: start + (index < 3 ? index * 1_000 : 579_000 + index * 1_000),
    dir,
    kind,
    msg,
  }));
}

const recording = (steps: Step[]) => ({
  events: async () =>
    `${events(steps)
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
});

/// Leo's sequence: the subagent ends with its report, and the agent's own one-line reply follows.
export const withReply = () => events([...prompt, subagent("completed"), ...notified("bg-1", "subagent", CALL, REPLY)]);

/// Opens the subagent's report from its line's words (a click anywhere on the line opens it): in the
/// narrow pane the first line, the toggle's own box, has no room left to click.
export const openReport = async (ctx: PlayContext) => {
  const toggle = { selector: ".cv-subagent-report-row .cv-agentmsg__words" };
  await ctx.waitFor(() => ctx.document.querySelector(toggle.selector));
  await ctx.click(toggle);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-done__report") !== null);
};

const opening = { checks: { layoutShiftMax: { value: 0.8, reason: "Opening the report reveals it below its line." } } };

export default agentPaneEntry({
  id: "agent-pane.notification-reply",
  title: "A notification row and the agent's reply after it",
  area: "Agent pane",
  height: 640,
  // The narrow pane is where the time fell off the line (subagents.css `.cv-subagent-report-row`).
  widths: { narrow: 380, normal: 760, wide: 1100 },
  covers: [
    "agent-session/acpmux/direct.ts#settleReaction",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  variants: {
    collapsed: {
      note: "Shipped, shut: the row is the subagent's mark, 'Subagent finished:', its name chip, the report's first line, the chevron, the new dot and its time. The agent's reply draws under it as its own message, at the reply column, with its own footer.",
      snapshot: chat([]),
      recording: recording([...prompt, subagent("completed"), ...notified("bg-1", "subagent", CALL, REPLY)]),
    },
    open: {
      note: "Shipped, opened: the line keeps its new dot and its time 9m 39s at the trailing column, and the chevron turned; the report's card under it; the agent's reply after the card, its own message.",
      snapshot: chat([]),
      recording: recording([...prompt, subagent("completed"), ...notified("bg-1", "subagent", CALL, REPLY)]),
      play: openReport,
      ...opening,
    },
    "no-reply": {
      note: "Shipped: the subagent ended and the agent said nothing: the row alone, nothing under it.",
      snapshot: chat([]),
      recording: recording([...prompt, subagent("completed"), ...notified("bg-1", "subagent", CALL, undefined)]),
    },
    "command-reply": {
      note: "Shipped: a background command's end and the agent's one-line reply: the call keeps its new dot, the reply draws as the agent's own message, never under the call's output.",
      snapshot: chat([]),
      recording: recording([...commandPrompt, ...notified("bg-2", "shell", SHELL, COMMAND_REPLY)]),
    },
  },
});
