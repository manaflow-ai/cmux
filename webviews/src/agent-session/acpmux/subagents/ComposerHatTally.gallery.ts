// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's `tally` header (trayFoldHead.experiment.ts, trayHeadKinds.ts `trayHeadParts`,
// SubagentTray.tsx `HeadKinds`). Leo, 2026-11-23: "my subagents idea displaying like that clearly
// didn't really work. because this is unusable at low widths. which is common. ... likewise, the timer.
// still hard line bullshit. ... hunch: just listing the # of each type of ongoing thing would be better.
// symbol for subagents, potentially per harness, then whatever other commands with their own symbols, a
// sort of count of states of affairs. animations that are unobtrisive. just like how the "running a
// command" is inherently bullshit, and the swap-in animation for it is even more additional bullshit.
// the fuck are these cutting off into ellipses so soon anyways?"; ""running" doesn't need text. it can
// usually just be. you can put symbols for state. and state can fucking only be relevant when you may
// need to investigate/take action."
//
// Each kind is its mark and its number: subagents one kind per harness (its logo), then each command
// kind; of what ended only a failure counts. No words, no separators, no faces, no ellipsis: a kind the
// row has no room for drops whole. The time never clips. The same layout narrow and wide.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, user, tool } from "../../../gallery/fixtures/acpmux";
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
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, Math.min(minutes, 4))),
    ...fields,
  };
}

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

/** Claude and Codex subagents, a test run and a server; one subagent done, one failed. */
const mixed = chat(
  [
    user("Review the tray from both sides and keep the tests going", 12),
    row(SUBAGENTS, 12, {
      subagents: [
        agent("Review the tray columns", 9, "running"),
        agent("Review the header counts", 8, "running"),
        agent("Cross-check the counts", 7, "running", { harness: "codex" }),
        agent("Find the screenshot", 11, "completed"),
        agent("Bisect the flaky fold test", 10, "failed"),
      ],
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 7),
        command("cd ~/Projects/app/webviews && bun test --watch", "Watch the tests", 3),
      ],
      7,
    ),
  ],
  { isWorking: true },
);

/** One background command, alone: counted as several are, never "Running a command". */
const lone = chat(
  [
    user("Watch the nightly", 3),
    activity([command("gh run watch 41723867191 --exit-status", "Wait for the nightly run", 2.5)], 3),
  ],
  { isWorking: true },
);

/** Twenty subagents over three harnesses and six commands of four kinds, at any width. */
const burst = chat(
  [
    user("Fan out over every package", 20),
    row(SUBAGENTS, 20, {
      subagents: Array.from({ length: 20 }, (_, index) =>
        agent(`Audit package ${index + 1}`, 19 - index * 0.5, "running", {
          harness: ["claude", "codex", "gemini"][index % 3]!,
        }),
      ),
    }),
    activity(
      [
        command("cd ~/Projects/app && bun run dev", "Run the dev server", 15),
        command("bun test --watch", "Watch the tests", 14),
        command("swift build -c release --product App", "Compile the head", 6),
        command("gh pr checks 34260 --watch", "Wait for the checks", 5),
        command("gh run watch 41723867191", "Wait for the nightly", 4),
        command("python3 scripts/check-test-determinism.py --runs 20", "Check test determinism", 3),
      ],
      15,
    ),
  ],
  { isWorking: true },
);

/** Twelve: eight subagents over three harnesses and four commands, the middle of the count matrix. */
const twelve = chat(
  [
    user("Split the review across the harnesses", 14),
    row(SUBAGENTS, 14, {
      subagents: Array.from({ length: 8 }, (_, index) =>
        agent(`Review part ${index + 1}`, 13 - index, "running", {
          harness: ["claude", "codex", "gemini"][index % 3]!,
        }),
      ),
    }),
    activity(
      [
        command("bun test --watch", "Watch the tests", 12),
        command("swift build -c release --product App", "Compile the head", 6),
        command("gh pr checks 34260 --watch", "Wait for the checks", 5),
        command("gh run watch 41723867191", "Wait for the nightly", 4),
      ],
      12,
    ),
  ],
  { isWorking: true },
);

/** Only finished, fine work: nothing to count, so the header keeps its own. */
const settled = chat(
  [user("Find the screenshot", 6), row(SUBAGENTS, 6, { subagents: [agent("Find the screenshot", 5, "completed")] })],
  { isWorking: true },
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

/** The tally's promises, at whatever width the stage has. */
function tallyHolds(ctx: PlayContext, minKinds: number): void {
  const header = head(ctx)!;
  const kinds = header.querySelector<HTMLElement>(".acpmux-running-tray__kinds[data-tally]");
  if (!kinds) throw new Error("no tally header");
  if (/running/i.test(header.textContent ?? "")) throw new Error(`the header says running: ${header.textContent}`);
  if (header.querySelector(".acpmux-running-tray__kind-sep, .acpmux-running-tray__latest"))
    throw new Error("the tally draws no separators and no step words");
  const row = kinds.getBoundingClientRect();
  const shown = [...kinds.querySelectorAll<HTMLElement>(".acpmux-running-tray__kind")].filter(
    (kind) => kind.getBoundingClientRect().top < row.bottom - 0.5,
  );
  if (shown.length < minKinds) throw new Error(`${shown.length} kinds shown, wanted ${minKinds}`);
  for (const kind of shown) {
    const box = kind.getBoundingClientRect();
    // Whole or not at all: no kind cut at the row's end, none into an ellipsis.
    if (box.right > row.right + 0.5) throw new Error(`${kind.dataset.kind} is cut at the row's end`);
    if (!/^\d+$/.test(kind.textContent ?? "")) throw new Error(`${kind.dataset.kind} reads "${kind.textContent}"`);
  }
  const time = header.querySelector<HTMLElement>(".acpmux-running-tray__time");
  if (time && time.scrollWidth > time.clientWidth + 0.5) throw new Error("the time is clipped");
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-tally",
  title: "Composer hat tally: a mark and a count per kind",
  area: "Agent pane",
  height: 360,
  // The width matrix: every variant (0, 1, 5, 12 and 26 things) at 280, 400 and 900 px; the play checks
  // the tally's promises in each cell.
  widths: { narrow: 280, normal: 400, wide: 900 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: {
    definition: trayFoldHeadLook,
    script: [
      {
        name: "show the header",
        run: async (ctx) => {
          await ctx.waitFor(() => head(ctx));
        },
      },
    ],
  },
  variants: {
    mixed: {
      note: "Two Claude subagents (2 by the Claude mark), a Codex one (1 by the Codex mark), a test run and a server, then the failed subagent's 1 in red. The done one is not counted: it needs nothing.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kinds[data-tally]"));
        tallyHolds(ctx, 2);
        if (!head(ctx)!.querySelector('[data-kind="failed"][data-tone="failed"]')) throw new Error("the failed count");
        if (head(ctx)!.querySelector('[data-kind="done"]')) throw new Error("done is not counted");
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "tally" },
    },
    "lone-command": {
      note: 'One background command: its wait mark and 1, the time after it. No "Running a command", nothing swapping in.',
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kinds[data-tally]"));
        tallyHolds(ctx, 1);
      },
      snapshot: lone,
      experiments: { "subagent-tray-fold-head": "tally" },
    },
    burst: {
      note: "Twenty subagents over Claude, Codex and Gemini and six commands: 7 · 7 · 6 by each logo, then each command kind's mark and number. Narrow, the kinds that do not fit drop whole; the time never clips.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kinds[data-tally]"));
        tallyHolds(ctx, 3);
      },
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "tally" },
    },
    twelve: {
      note: "Eight subagents (3 · 3 · 2 by the Claude, Codex and Gemini marks), a test run, a build and two waits. At 280 px the kinds that do not fit drop whole; the time never clips.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kinds[data-tally]"));
        tallyHolds(ctx, 2);
      },
      snapshot: twelve,
      experiments: { "subagent-tray-fold-head": "tally" },
    },
    settled: {
      note: "Only a finished subagent: nothing needs the person, so there is no tally; the header keeps the lone item's own.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx));
        if (head(ctx)!.querySelector(".acpmux-running-tray__kinds[data-tally]")) throw new Error("nothing to tally");
      },
      snapshot: settled,
      experiments: { "subagent-tray-fold-head": "tally" },
    },
    "kinds-before": {
      note: "The `kinds` arm it replaces, on the same work, for comparison: words, separators and the faces row.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx));
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "kinds" },
    },
  },
});
