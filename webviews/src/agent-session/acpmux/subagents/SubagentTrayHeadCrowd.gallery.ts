// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// A crowded running tray's header (SubagentTray.tsx): its kinds drop whole when they do not fit, and
// its time (trayHeadClock.experiment.ts). The header used to end mid-word and time the first item ever
// started. Leo, 2026-11-22: "this should not be cutting off so harshly like this. we basically never
// want that kinda shit. but to be honest, i have no idea what the point of putting time when there's
// shit like this supposed to be for. what the fuck are you timing man". Compare the times with the
// entry's experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayHeadClockLook } from "./trayHeadClock.experiment";

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

const command = (line: string, description: string | undefined, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, ...(description ? { description } : {}), run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

// The turn still runs: a command only the transcript knows is a tray line only while a turn runs
// (runningTray.ts `trayItems`).
const scene = (agents: Subagent[], commands: ReturnType<typeof command>[]) =>
  chat(
    [
      user("Land the tray PR: review it, run the tests and the compile, and wait on CI", 14),
      row(SUBAGENTS, 14, { subagents: agents }),
      activity(commands, 13),
      assistant("The reviewers, the checks and the waits keep running in the background.", 1),
    ],
    { isWorking: true },
  );

const many = Array.from({ length: 12 }, (_, index) =>
  running(`Sweep area ${index + 1} for stale copy`, 80 - index * 5, "Read the strings"),
);

const crowded = scene(many, [
  command("gh pr checks 4210 --watch", "Wait for the PR's checks", 30),
  command("gh run watch 9911223344", undefined, 20),
  command("cmux-ci test -- bun test test/subagent-tray.test.tsx", "Run the tray tests on the fleet", 9),
  command("cmux-ci compile-check --ref 1f2e3d4 --app", "Compile the app", 4),
  command("cd ~/Projects/app && bun run dev", "Run the dev server", 60),
]);

const twoKinds = scene(
  [running("Explore how the daemon updates itself", 2, "Read update.rs")],
  [command("gh run watch 9911223344 --exit-status", "Wait for CI", 7)],
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-head-crowd",
  title: "Crowded running tray header",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadClock.experiment.ts",
  ],
  experiment: {
    definition: trayHeadClockLook,
    script: [{ name: "the folded header", run: folded }],
  },
  variants: {
    crowded: {
      note: "Twelve subagents, waits, tests, a build and a server, folded: the kinds that fit, each whole; the rest drop off at a kind's edge, never mid-word. No time after them: each line has its own.",
      play: folded,
      snapshot: crowded,
    },
    "two-kinds": {
      note: "A subagent and a CI wait: `1 subagent running · 1 wait`, no header time.",
      play: folded,
      snapshot: twoKinds,
    },
  },
});
