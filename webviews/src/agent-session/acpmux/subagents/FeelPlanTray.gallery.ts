// l10n-allow-file: gallery fixtures (plan steps, commands), not shipped UI.
// The composer hat with the turn's plan, opened, for the feel check that drags its top rim
// (test/feel-plan-tray.test.ts). Leo, 2026-11-22: "the dragging isn't properly relative accurate to
// the cursor, and it's just jumpy all over the place and doesn't have satisfying snap alongs ...
// errant clicks could make it jump". The variants are the extremes a hand meets: one step, five,
// fifty, and steps with huge text.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxPlanEntry } from "../model";

const STEPS = [
  "Read the tray and its tests",
  "Move the plan into the hat",
  "Run the tray tests",
  "Compile the app on the fleet",
  "Update the design spec",
];
const HUGE =
  "Walk every surface that draws the hat (the bottom stack, a pinned chat, a split pane, the floating chat and the iPhone mirror) and check each keeps its height through a reload, a theme switch and a font size change";

function plan(count: number, huge = false): AcpmuxPlanEntry[] {
  return Array.from({ length: count }, (_, i) => ({
    content: huge ? `${HUGE} (${i + 1})` : count <= STEPS.length ? STEPS[i]! : `${STEPS[i % STEPS.length]} (${i + 1})`,
    status: i < Math.floor(count / 3) ? "completed" : i === Math.floor(count / 3) ? "in_progress" : "pending",
  }));
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "in_progress", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const snapshot = (count: number, huge = false) =>
  chat(
    [
      user("Land the tray change: compile, test and update the spec", 3),
      row("plan", 2.9, { plan: plan(count, huge) }),
      command("bun test webviews/src/agent-session/acpmux/subagents --timeout 30000", "run the hat tests", 2),
      command("cmux-ci compile-check --app --ref HEAD", "compile on the fleet", 1.5),
      assistant("The tests and the compile are running.", 0.5),
    ],
    { isWorking: true },
  );

const opened = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray[data-open] .acpmux-running-tray__list"));
};

export default agentPaneEntry({
  id: "agent-pane.feel-plan-tray",
  title: "Composer hat with a plan, opened: the feel check's stage",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/trayResize.ts"],
  variants: {
    one: { note: "One plan step and two commands.", play: opened, snapshot: snapshot(1) },
    five: { note: "Five plan steps and two commands.", play: opened, snapshot: snapshot(5) },
    fifty: { note: "Fifty plan steps: the list scrolls in place under the cap.", play: opened, snapshot: snapshot(50) },
    huge: { note: "Five steps of huge text: each cut at the row's edge.", play: opened, snapshot: snapshot(5, true) },
  },
});
