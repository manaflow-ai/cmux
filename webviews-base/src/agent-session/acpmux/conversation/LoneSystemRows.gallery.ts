// l10n-allow-file: gallery fixtures (sample prompts, commands, replies and agent names), not shipped UI.
// A lone system line between turns: the agent's own work that came in after its turn ended
// ("Background update", "Background task finished", "4 background tasks finished", "Subagent
// finished"), drawn under the turn's footer row with the next prompt under it. Leo, 2026-11-04, on a
// lone "Background update" a block gap under the footer and a turn gap over the next prompt: "this
// bare background update tool call floating in teh air is so weird loking proportionally". Each sits
// 8 under the footer, as the footer sits under the reply, so it reads as that turn's tail, and the
// turn gap stays under it (transcriptGrid.ts transcriptGap; design/transcript-spacing.md "Lone system
// rows"). Another agent's line there (variant received-message) is another speaker and keeps the
// block gap (footer-to-received). test/transcript-lone-system-rows.test.ts measures every variant.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "../subagents/subagentFold";
import { backgroundRunRowId } from "./backgroundRuns";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { backgroundTurnLook, drawsBackgroundTurnLines } from "./backgroundTurnLook.experiment";

/// The turn every variant starts with: a prompt, the reply and its footer row.
const opening = [
  user("Run the migration tests in the background and tell me if anything breaks", 12, { id: "lone-prompt" }),
  assistant("Started the migration tests in the background. I'll report when they finish.", 11.9, {
    id: "lone-reply",
  }),
  summary(11.9, { id: "lone-footer", status: "completed", durationMs: 4_000 }),
];
const next = user("Thanks, what's next on the list?", 2, { id: "lone-next" });

const quiet = (id: string, minutes: number, trigger = "system"): AcpmuxRow[] => [
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: { id, trigger, running: false, quiet: true, hasRows: true },
  }),
  activity(
    [tool("tail -n 3 out.log", "execute", "completed", { command: "tail -n 3 out.log", output: "14 passed" })],
    minutes - 0.03,
    { id: `${id}-work`, inBackground: id },
  ),
  assistant(".", minutes - 0.05, { id: `${id}-dot`, inBackground: id }),
];

const subagent: Subagent = {
  id: "lone-agent",
  parent: null,
  name: "Explore",
  task: "Find the migration runner",
  kind: "Explore",
  state: "completed",
  startedAt: minutesAgo(9),
  endedAt: minutesAgo(7),
  prompt: "Find the migration runner",
};

/// The line each variant measures (`data-row-id`), by variant.
export const LONE_LINE: Record<string, string> = {
  "background-update": backgroundTurnRowId("lone-bg"),
  "background-update-running": backgroundTurnRowId("lone-bg-running"),
  "scheduled-check-running": backgroundTurnRowId("lone-check-running"),
  "background-task": "lone-task",
  "background-tasks-run": backgroundRunRowId(backgroundTurnRowId("lone-run-a")),
  "subagent-finished": "subagentDone:lone-agent",
  "received-message": "lone-received",
};

export default agentPaneEntry({
  id: "agent-pane.lone-system-rows",
  title: "Lone system rows between turns",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/transcriptGrid.ts#transcriptGap",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  variants: {
    "background-update": {
      note: "Leo's capture: a quiet \"Background update\" after the turn ended, then the next prompt. It sits 8 under the footer row, the turn's tail, with the turn gap under it (before: 24 under the footer and 32 over the prompt, a lone line floating in the band).",
      snapshot: chat([...opening, ...quiet("lone-bg", 8), next]),
    },
    "background-update-running": {
      note: "The same line while its turn runs, a spinner, its words shimmering as a running tool row's, and no chevron, at the chat's end: 8 under the footer, so it does not move when it ends.",
      snapshot: chat([
        ...opening,
        row(BACKGROUND_TURN, 8, {
          id: backgroundTurnRowId("lone-bg-running"),
          background: { id: "lone-bg-running", trigger: "system", running: true },
        }),
      ]),
    },
    "scheduled-check-running": {
      note: 'Leo, 2026-11-09: "this scheduled check thing isn\'t highlighted all the way through like other tool calls are". A running "Scheduled check": the shimmer crosses the whole label, as on a running tool row (before: a spinner and still words).',
      snapshot: chat([
        ...opening,
        row(BACKGROUND_TURN, 8, {
          id: backgroundTurnRowId("lone-check-running"),
          background: { id: "lone-check-running", trigger: "scheduled", running: true },
        }),
      ]),
    },
    "background-task": {
      note: '"Background task finished" for the command the turn started, after the turn ended: 8 under the footer.',
      snapshot: chat([
        ...opening,
        row("backgroundTask", 8, {
          id: "lone-task",
          backgroundTask: { toolCallId: "lone-task", command: "bun test migrations", state: "completed" },
        }),
        next,
      ]),
    },
    "background-tasks-run": {
      note: '"3 background tasks finished", a run of quiet task turns folded under one line: 8 under the footer.',
      snapshot: chat([
        ...opening,
        ...quiet("lone-run-a", 9, "task_notification"),
        ...quiet("lone-run-b", 8, "task_notification"),
        ...quiet("lone-run-c", 7, "task_notification"),
        next,
      ]),
    },
    "subagent-finished": {
      note: '"Subagent finished" for a subagent that ended after the turn: 8 under the footer.',
      snapshot: chat([
        ...opening,
        {
          id: "subagentDone:lone-agent",
          version: 1,
          kind: "subagentDone",
          at: subagent.endedAt!,
          subagents: [subagent],
        },
        next,
      ]),
    },
    "background-update-hover": {
      note: '"Background update" under the pointer: its words light all the way through, as a tool row\'s do; its clock stays (Leo, 2026-11-09).',
      snapshot: chat([...opening, ...quiet("lone-bg", 8), next]),
      play: async (ctx) => {
        // The line look's line (backgroundTurnLook.experiment.ts); the inline look draws none.
        if (!drawsBackgroundTurnLines()) return;
        await ctx.hover({ selector: "button.cv-background-turn .cv-agent-activity__sentence" });
      },
    },
    "background-tasks-run-hover": {
      note: '"3 background tasks finished" under the pointer: its words light all the way through, as a tool row\'s do (Leo, 2026-11-09).',
      snapshot: chat([
        ...opening,
        ...quiet("lone-run-a", 9, "task_notification"),
        ...quiet("lone-run-b", 8, "task_notification"),
        ...quiet("lone-run-c", 7, "task_notification"),
        next,
      ]),
      play: async (ctx) => {
        // The line look's line (backgroundTurnLook.experiment.ts); the inline look draws none.
        if (!drawsBackgroundTurnLines()) return;
        await ctx.hover({ selector: "button.cv-background-turn .cv-agent-activity__sentence" });
      },
    },
    "subagent-finished-hover": {
      note: '"Subagent finished" with the pointer on its name: only the name chip lights, the line opens nothing (Leo, 2026-11-05: "subagents need to have their clickable bit be highlighted instead of the whole line click").',
      snapshot: chat([
        ...opening,
        {
          id: "subagentDone:lone-agent",
          version: 1,
          kind: "subagentDone",
          at: subagent.endedAt!,
          subagents: [subagent],
        },
        next,
      ]),
      play: async (ctx) => ctx.hover({ selector: ".cv-subagent-done button.cv-agent-tag.is-open" }),
    },
    "received-message": {
      note: "Another agent's message after the turn ended keeps the block gap under the footer (footer-to-received, 51 centre to centre): it is another speaker, not this turn's tail.",
      snapshot: chat([
        ...opening,
        user("Review passed at e34ce27.", 8, {
          id: "lone-received",
          incoming: {
            kind: "message",
            message: { name: "review-box", text: "Review passed at e34ce27.", raw: "Review passed at e34ce27." },
          },
        }),
        next,
      ]),
    },
  },
  // Compare arms: the turn's calls inline (default, Leo 2026-11-11) and the line look these variants first drew.
  experiment: {
    definition: backgroundTurnLook,
    script: [{ name: "hover the first row", run: async (ctx) => ctx.hover({ selector: ".cv-tool" }) }],
  },
});
