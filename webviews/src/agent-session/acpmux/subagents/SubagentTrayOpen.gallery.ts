// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The running tray's header expands in place OR opens the full Background tasks panel
// (SubagentTray.tsx `onOpenPanel`, trayOpen.experiment.ts). Leo, 2026-11-03, on Claude's "9
// background commands completed, 3 running ›" chip beside its Background tasks panel: "i feel like
// having a thing like this that can either expand OR open up to this sort of thing would be quite
// cool...". The default arm keeps the header's expand and adds a panel button in the lines' Stop
// column, right before the chevron; compare it with the whole-header arm (Claude's chip) and none.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayOpenLook } from "./trayOpen.experiment";

const running = (task: string, minutes: number, action: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const snapshot = chat([
  user("Fan the review out and keep the checks running while I look", 12),
  row(SUBAGENTS, 12, {
    subagents: [
      running("Add rail spec section", 4, "Read running-tray.md"),
      running("Review the fold", 2, "Grep useFold"),
    ],
  }),
  activity([command("cd ~/Projects/app && bun run dev", "Run the dev server", 8)], 11),
  assistant("The reviewers and the dev server keep running in the background.", 1),
  summary(1, { status: "completed", durationMs: 600_000, toolCount: 3 }),
]);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
};
const hovered = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__open"));
  await ctx.hover({ selector: ".acpmux-running-tray__open" });
};
const opened = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.click({ selector: ".acpmux-running-tray__open" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-bg"));
};
const expanded = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list .acpmux-agent-line"));
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-open",
  title: "Running tray expands or opens Background tasks",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/trayOpen.experiment.ts"],
  experiment: {
    definition: trayOpenLook,
    script: [{ name: "the folded header", run: folded }],
  },
  variants: {
    folded: {
      note: "Folded: the header names what runs (#33104), then its time, the panel button in the lines' Stop column, then the chevron.",
      play: folded,
      snapshot,
    },
    hover: {
      note: "The panel button hovered: its own highlight, never the header row's.",
      play: hovered,
      snapshot,
    },
    expanded: {
      note: "A click on the header still expands the tray in place; the panel button stays on the header.",
      play: expanded,
      snapshot,
    },
    "opens-panel": {
      note: "The panel button opens the full Background tasks panel in the chat's right column, Running and Finished.",
      play: opened,
      snapshot,
    },
  },
});
