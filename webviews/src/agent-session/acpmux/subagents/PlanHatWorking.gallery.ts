// l10n-allow-file: gallery fixtures (plan steps), not shipped UI.
// The composer hat holding only a plan (cmux#51039; the person, 2026-11-22, on "0 of 6 · Read prior
// fixes, find real cause" with nothing turning: "this is confusing i wasn't sure if this workspace was
// doing anything"). While the turn runs, the header spins and counts the turn's time and the step at
// work spins; between turns the kept list rests, its step in progress a plain ring. Every step of a
// six-step plan shows; a longer one scrolls with the step at work in view.
import { agentPaneEntry } from "../../../gallery/format";
import { chat, row, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxPlanEntry, AcpmuxSnapshot } from "../model";

const STEPS = [
  "Read prior fixes, find real cause",
  "Write failing regression test",
  "Fix and get test green",
  "Dev build, repro and verify",
  "Open PR, post issue evidence",
  "Squash-merge once verified",
  "Post the evidence on the issue",
  "Clean up the worktree",
  "Close the dev build",
  "Report back",
];

const plan = (count: number, at: number): AcpmuxPlanEntry[] =>
  STEPS.slice(0, count).map((content, i) => ({
    content,
    status: i < at ? "completed" : i === at ? "in_progress" : "pending",
  }));

const working = (count: number, at: number) =>
  chat([user("Fix the plan card: show the chat is working", 4), row("plan", 3.9, { plan: plan(count, at) })], {
    isWorking: true,
    turnStartedAtMs: Date.now() - 4 * 60_000,
  });

/// Between turns: the chat's kept list (acpmux `taskList`) with steps left, as the hat shows it.
const between = (): AcpmuxSnapshot => {
  const items = plan(6, 0);
  const snapshot = chat([user("Fix the plan card: show the chat is working", 9)]);
  return {
    ...snapshot,
    summary: { ...snapshot.summary!, taskList: { source: "harness", done: 0, total: 6, items, updatedAt: 1 } },
  };
};

const opened = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray[data-open] .acpmux-running-tray__plan"));
};

export default agentPaneEntry({
  id: "agent-pane.plan-hat-working",
  title: "Composer hat with only a plan: working, and between turns",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/conversation/PlanList.tsx",
    "agent-session/acpmux/chatTaskList.ts",
  ],
  variants: {
    working: {
      note: "Six steps while the turn runs: the header spins and counts, the step at work spins, all six show.",
      play: opened,
      snapshot: working(6, 0),
    },
    "working-long": {
      note: "Ten steps, the eighth at work: the list scrolls in place with that step in view.",
      play: opened,
      snapshot: working(10, 7),
    },
    between: {
      note: "Between turns: the kept list rests, its step in progress a plain ring, the header quiet.",
      play: opened,
      snapshot: between(),
    },
  },
});
