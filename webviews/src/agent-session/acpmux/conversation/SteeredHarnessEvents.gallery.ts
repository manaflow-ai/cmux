// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands and replies), not shipped UI.
// Harness events that arrive after a steer are tool-call work, not standalone rows. Leo, 2026-11-24,
// on a chat that drew "Subagent disconnected: <task> > 1h 14m 51s" a dozen times and "36 background
// commands finished" after the person's steer: "we can initiate the Worked for with these background
// tasks as actual tool calls. we can indeed treat them as tool calls, even though they're bursted at
// the end/start of turns. thereby we can have them be folded properly too."
// A subagent's end folds as a run member like a shell's end (backgroundRuns.ts), and no longer stays
// out of the turn's fold (turns.ts `staysOut`), except one that failed: it waits on a Retry.
// steeredHarnessEvents.test.tsx holds the model. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { backgroundRunRowId } from "./backgroundRuns";

const LANES = [
  "Land the composer geometry lane",
  "Check the nightly macOS build",
  "Rerun the risk evidence check",
  "Review the sidebar drag fix",
  "Wait for the iOS placeholder audit",
  "Bisect the stalled cloud sync",
];
const WAITS = [
  "gh pr checks 53101 --watch",
  "Wait for rust test run",
  "Peek at both runs",
  "Block on verdict wait",
  "CI rollup for 52990 and 53012",
  "Wait for codegen EXIT",
];

const ended = (index: number, state: string, minutes: number): AcpmuxRow =>
  row("subagentDone", minutes, {
    id: `subagentDone:steered-${index}`,
    subagents: [
      {
        id: `steered-${index}`,
        parent: null,
        name: `helper-${index + 1}`,
        task: LANES[index % LANES.length]!,
        state,
        startedAt: minutesAgo(90),
        endedAt: minutesAgo(minutes),
      } as never,
    ],
  } as Partial<AcpmuxRow>);
const shell = (index: number, minutes: number, state: "completed" | "failed" | "stopped" = "completed"): AcpmuxRow =>
  row("backgroundTask", minutes, {
    id: `steered-wait-${index}`,
    backgroundTask: {
      toolCallId: `steered-wait-${index}`,
      command: WAITS[index % WAITS.length]!,
      state,
      ...(state === "failed" && { exitCode: 1 }),
      ownerTitle: `helper ${(index % 12) + 1}`,
    },
  });

/// The person's prompt, the agent's work, their steer, the agent's answer to it, then the harness's burst.
const steered = (burst: AcpmuxRow[]): AcpmuxRow[] => [
  user("Keep the lanes moving and land what goes green", 20),
  activity(
    [
      tool("gh pr checks 53101 --watch", "execute", "completed", {
        command: "gh pr checks 53101 --watch",
        output: "green",
      }),
    ],
    19.5,
  ),
  user("Also check lane 9 before you stop", 18, { steer: "landed" }),
  assistant("Checked lane 9: it is green and landed. The other lanes are still running.", 16),
  summary(16, { status: "completed", durationMs: 240_000, toolCount: 1 }),
  ...burst,
];

/// Leo's chat: 12 subagents disconnected, then 36 background commands ended, all after the steer.
const burst = (): AcpmuxRow[] => [
  ...Array.from({ length: 12 }, (_, i) => ended(i, "disconnected", 15 - i * 0.05)),
  ...Array.from({ length: 36 }, (_, i) => shell(i, 14 - i * 0.05)),
];
/// Ends that differ: finished, stopped, disconnected, and one failed subagent, among shells.
const mixedBurst = (): AcpmuxRow[] => [
  ended(0, "completed", 15),
  ended(1, "cancelled", 14.9),
  ended(2, "disconnected", 14.8),
  ended(3, "failed", 14.7),
  ended(4, "completed", 14.6),
  ...Array.from({ length: 8 }, (_, i) => shell(i, 14.5 - i * 0.05)),
];

const RUN = backgroundRunRowId("subagentDone:steered-0");

/// Opens what the burst folded into: the turn's "Worked for" when it holds the run, then the run.
const openBurst = async (ctx: PlayContext) => {
  const line = `[data-row-id="${RUN}"] .cv-background-turn`;
  const worked = "button.cv-worked.is-toggle";
  await ctx.waitFor(() => ctx.document.querySelector(line) !== null || ctx.document.querySelector(worked) !== null);
  if (!ctx.document.querySelector(line)) {
    await ctx.click({ selector: worked });
    await ctx.waitFor(() => ctx.document.querySelector(line) !== null);
  }
  if (ctx.document.querySelector(line)?.getAttribute("aria-expanded") !== "true") {
    await ctx.click({ selector: line });
    await ctx.waitFor(() => ctx.document.querySelector(line)?.getAttribute("aria-expanded") === "true");
  }
};

export default agentPaneEntry({
  id: "agent-pane.steered-harness-events",
  title: "Harness events after a steer fold as tool calls",
  area: "Agent pane",
  height: 620,
  covers: [
    "agent-session/acpmux/conversation/backgroundRuns.ts",
    "agent-session/acpmux/conversation/turns.ts#staysOut",
  ],
  variants: {
    closed: {
      note: "Leo's chat: after the steer, 12 subagents disconnected and 36 background commands ended. They fold as the turn's tool-call work into one closed line, with no Subagent disconnected row of its own.",
      snapshot: chat(steered(burst())),
    },
    open: {
      note: "The same burst opened: each subagent's end and each command's end again, in order. Play: open the fold and the run.",
      snapshot: chat(steered(burst())),
      play: openBurst,
      checks: {
        layoutShiftMax: {
          value: 0.8,
          reason: "Opening the fold reveals its rows below the clicked line.",
        },
      },
    },
    mixed: {
      note: "Ends that differ (finished, stopped, disconnected) and shells read as one count, 13 background updates; the one subagent that failed stays in sight outside the Worked for, counted and named in red: 1 failed.",
      snapshot: chat(steered(mixedBurst())),
    },
  },
});
