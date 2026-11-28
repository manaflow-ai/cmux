// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// Leading Pair composer crown (trayFoldHead.experiment.ts `crown`, SubagentTray.tsx).
// Opaque recessed crown joined above the borderless composer with monochrome 9+ corner sub-badges
// for subagents and background commands side by side on the left (no divider, command badge
// non-clickable), steady hide/panel icons, and flat direct-click open rows with zero-shift Stop.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";

function agent(task: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  return {
    id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state,
    background: true,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, Math.min(minutes, 2))),
    ...fields,
  };
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const loneFinished = chat(
  [
    user("Improve todo.html so the layout feels cleaner and has keyboard shortcuts", 4),
    row(SUBAGENTS, 4, {
      subagents: [agent("Improve todo.html layout and keyboard shortcuts", 1, "completed", { harness: "claude" })],
    }),
  ],
  { isWorking: false },
);

const loneCommand = chat(
  [
    user("Run the subagent test suite in the background", 2),
    activity([command("bun test webviews/subagents", "Run subagent tests", 0.5)], 2),
  ],
  { isWorking: true },
);

const mixed = chat(
  [
    user("Audit the composer hat tokens, focus traps, and tests in parallel", 6),
    row(SUBAGENTS, 6, {
      subagents: [
        agent("Refactor composer hat tokens", 2, "running", { harness: "claude" }),
        agent("Audit keyboard focus traps", 1, "running", { harness: "codex" }),
        agent("Improve todo.html layout", 3, "completed", { harness: "claude" }),
      ],
    }),
    activity([command("bun test webviews/subagents", "Run subagent tests", 0.5)], 5),
  ],
  { isWorking: true },
);

const swarm = chat(
  [
    user("Fan out layout, contrast, and rust tests in parallel", 14),
    row(SUBAGENTS, 14, {
      subagents: Array.from({ length: 12 }, (_, index) =>
        agent(`Audit package ${index + 1}`, 12 - index * 0.5, "running", {
          harness: index % 3 === 0 ? "codex" : "claude",
        }),
      ),
    }),
    activity(
      [
        command("bun test webviews/subagents", "Run subagent tests", 4),
        command("cargo test -p acpmux bg_tasks", "Run acpmux bg_tasks tests", 3),
      ],
      10,
    ),
  ],
  { isWorking: true },
);

const openCrown = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray[data-crown]") ?? undefined);
  const head = ctx.document.querySelector<HTMLButtonElement>(".acpmux-running-tray__head");
  if (head?.getAttribute("aria-expanded") === "false") head.click();
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-crown__row") ?? undefined);
};

export default agentPaneEntry({
  id: "agent-pane.composer-hat-crown",
  title: "Composer hat: Leading Pair crown",
  area: "Agent pane",
  height: 400,
  widths: { narrow: 320, normal: 520, wide: 820 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/crownModel.ts",
    "agent-session/acpmux/subagents/crownHat.css",
  ],
  experiment: {
    definition: trayFoldHeadLook,
    script: [
      {
        name: "show the crown",
        run: (ctx) =>
          ctx.waitFor(() => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray[data-crown]") ?? undefined),
      },
    ],
  },
  keywords: ["composer hat", "leading pair", "crown", "subagents", "background tasks"],
  variants: {
    "mixed-closed": {
      note: "Leading Pair closed: subagent and command icon sub-badges side by side with no divider.",
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "crown" },
    },
    "mixed-open": {
      note: "Leading Pair open: flat inset rows with no divider, no details, and direct-click navigation.",
      play: openCrown,
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "crown" },
    },
    "swarm-open": {
      note: "12 running subagents + 2 running commands: subagent badge caps at 9+, list scrolls past 5 rows.",
      play: openCrown,
      snapshot: swarm,
      experiments: { "subagent-tray-fold-head": "crown" },
    },
    "lone-finished": {
      note: "Single finished subagent: 1-line direct-click crown with no badge chrome.",
      snapshot: loneFinished,
      experiments: { "subagent-tray-fold-head": "crown" },
    },
    "lone-command": {
      note: "Single running command: 1-line direct-click crown with spinner and steady header controls.",
      snapshot: loneCommand,
      experiments: { "subagent-tray-fold-head": "crown" },
    },
  },
});
