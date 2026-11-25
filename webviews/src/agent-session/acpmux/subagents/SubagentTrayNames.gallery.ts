// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The running tray's folded header names what runs (SubagentTray.tsx, trayFoldHead.experiment.ts).
// Leo, 2026-11-03: "the "running" bar above the composer is currently no longer usable bc it doesn't
// display much", on a bar that read only "1 subagent running · 1 command 4s". Folded, it now reads as
// Claude Code's running-tasks list does: the subagent's task and the command's description, newest
// first; with more running, the newest two and "+N more"; in a narrow pane, the newest one. It stays
// one row. Compare the arms (newest two, newest one, counts) with the entry's experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";

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
// (runningTray.ts `trayItems`; the gallery has no process registry to vouch for it between turns).
const scene = (agents: Subagent[], commands: ReturnType<typeof command>[]) =>
  chat(
    [
      user("Fan the review out and keep the checks running while I look", 12),
      row(SUBAGENTS, 12, { subagents: agents }),
      activity(commands, 11),
      assistant("The reviewers and the checks keep running in the background.", 1),
    ],
    { isWorking: true },
  );

const onePlusOne = scene(
  [running("Explore how the daemon updates itself", 0.2, "Read update.rs")],
  [command("cd ~/Projects/app/webviews && bun test --watch", "Watch the tests", 0.1)],
);

const five = scene(
  [
    running("Review the tray", 9, "Read SubagentTray.tsx"),
    running("Review the fold", 7, "Grep useFold"),
    running("Audit the bottom stack", 0.5, "Read bottomStack.css"),
  ],
  [
    command("cd ~/Projects/app && bun run dev", "Run the dev server", 8),
    command("cd ~/Projects/app/webviews && bun run lint", undefined, 0.2),
  ],
);

const long = scene(
  [
    running(
      "Find every place the composer's attachment strip measures its chips and check none reads layout per token",
      1,
      "Grep measure",
    ),
  ],
  [
    command(
      "cd ~/Projects/app/webviews && bun test test/composer-attachments.test.ts --timeout 60000",
      "Run the composer attachment tests against the new chip layout",
      0.3,
    ),
  ],
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-names",
  title: "Running tray folded header names what runs",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayFoldHead.experiment.ts",
  ],
  experiment: {
    definition: trayFoldHeadLook,
    script: [{ name: "the folded header", run: folded }],
  },
  variants: {
    "one-plus-one": {
      note: "One subagent and one command, folded: the command's description, then the subagent's task, newest first, then the time and the chevron.",
      play: folded,
      snapshot: onePlusOne,
    },
    five: {
      note: "Five running, folded: the newest two by name, then +3 more; the bar stays one row.",
      play: folded,
      snapshot: five,
    },
    "long-narrow": {
      note: "A long task and a long description; at the narrow width (360px) only the newest shows, truncating, and +1 more and the time never cut.",
      play: folded,
      snapshot: long,
    },
  },
});
