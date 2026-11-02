// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// The settled tray (SubagentTray.tsx): nothing runs, four subagents ended, the tray opened. Leo's
// screenshot (2026-11-01) showed it on the chat's own glass with a 3/4 ring before "Subagents" and a
// "View all 4" row under three lines: "why did you guys not remove the 3/4 and why did you still not
// fix the stupid gap and you fucking glassed way too hard now there's no difference at all but ok but
// why is there even a view all 5 button it's useless just let it be scroll-downable". Here the header
// has no mark, every line is in the list (it scrolls past five), and the tray keeps a surface of its
// own: compare the arms of traySurface.experiment.ts (view Compare arms); `tint` ships.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { traySurfaceLook } from "./traySurface.experiment";

const ended = (name: string, minutes: number, ran: number): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task: name,
  state: "completed",
  startedAt: minutesAgo(minutes),
  endedAt: minutesAgo(minutes - ran),
});

const settled = (count: number) =>
  chat(
    [
      user("Review the fix at its head, then research what the image should carry", 30),
      row(SUBAGENTS, 30, {
        subagents: [
          ended("Delta review of the tray fix", 29, 4),
          ended("Review the tray fix at its head", 28, 6),
          ended("Research what to bake into the image", 27, 9),
          ended("Check the docs agree", 26, 3),
          ...Array.from({ length: Math.max(0, count - 4) }, (_, index) =>
            ended(`Lane ${String(index + 1).padStart(2, "0")}`, 25 - index * 0.2, 1),
          ),
        ],
      }),
      assistant("Both reviews say ship; the research notes are in the issue.", 1),
    ],
    { isWorking: false },
  );

const open = async (ctx: PlayContext) => {
  const head = () => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  await ctx.waitFor(head);
  if (head()!.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray__list .acpmux-agent-line").length >= 4);
  if (ctx.document.querySelector(".acpmux-running-tray__finished")) throw new Error("the tray has no View all");
  const mark = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head .acpmux-lineage__icon");
  if (mark && getComputedStyle(mark).visibility !== "hidden") throw new Error("the header shows no mark");
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-surface",
  title: "Settled tray surface",
  area: "Agent pane",
  height: 420,
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/traySurface.experiment.ts",
  ],
  experiment: {
    definition: traySurfaceLook,
    script: [{ name: "the opened settled tray", run: open }],
  },
  variants: {
    four: {
      note: "Leo's tray: four subagents ended, opened. No header mark, no View all, a faint surface of its own joined to the composer.",
      play: open,
      snapshot: settled(4),
    },
    twelve: {
      note: "Twelve ended: the list shows five lines and scrolls; nothing under it.",
      play: open,
      snapshot: settled(12),
    },
  },
});
