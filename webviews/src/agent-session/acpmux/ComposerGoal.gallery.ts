// l10n-allow-file: gallery fixtures (goals, prompts, subagent names), not shipped UI.
// The chat's goal as a row of the composer hat (TaskGoalStrip.tsx `GoalStrip`). Leo, 2026-11-09, on
// a reference goal pill: "i like this goal ui ... but ALSO that rapid click togle on/of fand its speed
// too ... i wonder why they didnt have hover to see the goal? seems weird. and no expansion of the
// goal in place either. hm. i think..  i wonder hwo we wanna have it with the composer hat."
// Folded it is one line (state, cut objective, tabular time, chevron); a resting pointer shows the
// whole goal in a hover card; a click opens it in place, and Edit turns the text into a field there.
// The experiment compares where it sits with the hat (goalHat.experiment.ts; view Compare arms).
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, row, user } from "../../gallery/fixtures/acpmux";
import { GALLERY_NOW, minutesAgo } from "../../gallery/clock";
import type { PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import type { TaskGoal } from "./goal";
import { goalHatPlace } from "./goalHat.experiment";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

const OBJECTIVE =
  "Continue splitting and landing the remaining focused cmux-next PRs from the review queue, one at a time, each with an exact-head review and a green compile, and stop when the queue is empty";

const goal = (status: TaskGoal["status"], objective = OBJECTIVE): TaskGoal => ({
  objective,
  status,
  provider: "codex",
  startedAt: GALLERY_NOW - (32 * 60 + 22) * 1000,
  updatedAt: GALLERY_NOW - 4 * 60_000,
  ...(status === "done" ? { endedAt: GALLERY_NOW - 4 * 60_000 } : {}),
});

const agent = (name: string, minutes: number, action: string): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task: name,
  state: "running",
  startedAt: minutesAgo(minutes),
  action,
});

/** A Codex chat with `status`'s goal; `hat` adds two running subagents and a queued prompt under it. */
function goalChat(status: TaskGoal["status"], hat = false, objective?: string): AcpmuxSnapshot {
  const rows = [
    user("Keep going on the review queue", 34),
    assistant("Landed #38102. Splitting the next one.", 6),
    ...(hat
      ? [
          row(SUBAGENTS, 5, {
            subagents: [
              agent("Review the next split", 5, "Read land_ready.py"),
              agent("Compile check at head", 3, "Bash"),
            ],
          }),
        ]
      : []),
  ];
  const snapshot = chat(rows, {
    harness: "codex",
    model: "gpt-6-astra",
    isWorking: status === "running",
    ...(hat ? { queue: [{ id: "next", prompt: "After this one, check the nightly." }] } : {}),
  });
  return { ...snapshot, summary: { ...snapshot.summary!, harness: "codex", goal: goal(status, objective) } };
}

const line = { selector: ".acpmux-goal-toggle" };
const section = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-goal[data-look]");
const opened = (ctx: PlayContext) => section(ctx)?.hasAttribute("data-open") === true;

const open: (ctx: PlayContext) => Promise<void> = async (ctx) => {
  await ctx.click(line);
  await ctx.waitFor(() => opened(ctx));
};

const script = [
  {
    name: "a resting pointer shows the whole goal; the hat does not move",
    run: async (ctx: PlayContext) => {
      await ctx.hover(line);
      await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-goal-preview")), { capMs: 3000 });
    },
  },
  {
    name: "a click opens it in place; its first line stays",
    run: open,
  },
  {
    name: "a second click folds it",
    run: async (ctx: PlayContext) => {
      await ctx.click(line);
      await ctx.waitFor(() => !opened(ctx));
    },
  },
];

export default agentPaneEntry({
  id: "agent-pane.composer-goal",
  title: "Composer hat: the chat's goal",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  // The composer stays put while the goal opens, folds or is edited: the hat grows upward.
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/TaskGoalStrip.tsx#TaskGoalStrip",
    "agent-session/acpmux/TaskGoalStrip.css",
    "agent-session/acpmux/goalHat.experiment.ts",
  ],
  experiment: { definition: goalHatPlace, script },
  variants: {
    stalled: {
      note: "A stalled goal alone: one line in the hat's glass, its objective cut, the time in tabular figures; the buttons fade in over the cut end on hover or focus.",
      snapshot: goalChat("stalled"),
    },
    "with-hat": {
      note: "The goal heads the hat over two running subagents and a queued prompt: one glass stack, every time and chevron in the same trailing columns.",
      snapshot: goalChat("running", true),
    },
    "with-hat-open": {
      note: "Opened in place over the running lines: the objective's first line stays where it was, the rest and Updated unfold under it, the hat grows upward.",
      snapshot: goalChat("running", true),
      play: open,
    },
    hover: {
      note: "A resting pointer on the cut line: the whole goal and when it changed in a hover card over the transcript; nothing in the hat moves.",
      snapshot: goalChat("stalled", true),
      play: async (ctx) => {
        await ctx.hover(line);
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-goal-preview")), { capMs: 3000 });
      },
    },
    editing: {
      note: "Edit turns the text into a field in the same place and type; Return sends it as the new goal, Escape keeps the old.",
      snapshot: goalChat("paused", true),
      play: async (ctx) => {
        await ctx.hover(line);
        await ctx.click({ selector: '.acpmux-goal [aria-label="Edit goal"]' });
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-goal-field")));
      },
    },
    "rapid-toggle": {
      note: "Fifteen clicks 60 ms apart (the reference took 68 ms clicks without dropping one): each turns the fold around from where it is, and the last leaves it open.",
      snapshot: goalChat("stalled", true),
      play: async (ctx) => {
        for (let click = 0; click < 15; click++) {
          await ctx.click(line);
          await new Promise((resolve) => setTimeout(resolve, 60));
        }
        await ctx.waitFor(() => opened(ctx));
      },
    },
    paused: {
      note: "Paused: a hollow mark; Resume takes Pause's place.",
      snapshot: goalChat("paused"),
    },
    met: {
      note: "Met: the mark in the success colour, the total time, no Pause or Resume.",
      snapshot: goalChat("done"),
    },
    short: {
      note: "A goal short enough to fit: no hover card, since nothing is cut.",
      snapshot: goalChat("running", false, "Fix the flaky retry test"),
    },
  },
});
