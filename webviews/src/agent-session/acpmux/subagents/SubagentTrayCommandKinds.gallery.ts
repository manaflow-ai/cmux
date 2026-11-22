// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The running tray's header counts the commands by what they do (trayCommandKinds.ts, trayHeadKinds.ts).
// Leo, 2026-11-03: "you can split up commands/waits/bg tasks/subagents/maybe agent sessions you
// expect something from and maybe more if you can think like what KINDS of background commands
// run... so you can fit that all in counts of stuff and maybe times all in one line like a \ b \ c
// or a | b| c or a / b / c and whatnot". Messages to other agents, reviews, test runs, builds, waits
// on CI, a PR or a log, servers and the other commands each count apart, and each command's line
// carries its kind's mark. Compare the separators (middot, slash, pipe, backslash) with the entry's
// experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayKindLineLook } from "./trayKindLine.experiment";

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

// A coordinator's turn: every kind at once.
const everyKind = scene(
  [
    running("Review the tray header", 9, "Read SubagentTray.tsx"),
    running("Audit the bottom stack", 4, "Read bottomStack.css"),
  ],
  [
    command("router-review manaflow-ai/app 4210 --post", "Review the PR at its head", 6),
    command("cmux-ci test -- bun test test/subagent-tray.test.tsx", "Run the tray tests on the fleet", 5),
    command("cmux-ci compile-check --ref 1f2e3d4 --app", "Compile the app", 3),
    command("gh pr checks 4210 --watch", "Wait for the PR's checks", 12),
    command("gh run watch 9911223344", undefined, 2),
    command("cd ~/Projects/app && bun run dev", "Run the dev server", 11),
    command('acpmux send review-lane "The header counts by kind now: check the narrow width"', undefined, 1),
    command("tail -f /tmp/app.log", "Follow the log", 0.5),
    command("rg -n TODO src > /tmp/todos.txt", "List the TODOs", 0.3),
  ],
);

// The usual small case: a subagent and a wait.
const twoKinds = scene(
  [running("Explore how the daemon updates itself", 2, "Read update.rs")],
  [command("gh run watch 9911223344 --exit-status", "Wait for CI", 7)],
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
};
const opened = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
  if (head(ctx)?.getAttribute("aria-expanded") !== "true") {
    await ctx.click({ selector: ".acpmux-running-tray__head" });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list"));
  }
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-command-kinds",
  title: "Running tray counts commands by what they do",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayCommandKinds.ts",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/trayKindLine.experiment.ts",
  ],
  experiment: {
    definition: trayKindLineLook,
    script: [{ name: "the folded header", run: folded }],
  },
  variants: {
    "every-kind": {
      note: "Eleven things run, folded: two subagents, then a message to another chat, a review, a test run, a build, three waits (a PR's checks, a run and a log), a server and a command, each counted apart; the oldest one's time after them.",
      play: folded,
      snapshot: everyKind,
    },
    "every-kind-open": {
      note: "The same, opened: the header keeps its counts, and each command's line carries the mark of the kind it counts under in place of the word Command.",
      play: opened,
      snapshot: everyKind,
    },
    "two-kinds": {
      note: "A subagent and a CI wait: `1 subagent running · 1 wait`, then the time.",
      play: folded,
      snapshot: twoKinds,
    },
  },
});
