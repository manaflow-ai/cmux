// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

let serial = 0;
function agent(task: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  serial += 1;
  return {
    id: `agent-${serial}-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
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

const RUNNING_TASKS = [
  ["Base reds: clippy + #41472", "That edit left the match arm tangled. Rewriting the arm cleanly."],
  ["Fix #41540 and land", "Rebased on the new base; running the focused tests again before the push."],
  ["Nightly cancel regression", "The cancel path drops the run's lease before the upload finishes."],
  ["merge_hold merge-race guard", "Two holds raced on the same head; reading the lock's history."],
  ["Blank top region fix", "The dock measures before the font loads; moving the read after it."],
  ["Review cmux#41724", "Reading the diff of the composer's rest gap against the transcript's."],
  ["Transcript stage 1 rows in Rust", "Porting the row builder; the fold tests pass, the tail ones next."],
  ["Audit the sidebar's unread dots", "Three surfaces read the same flag at different times."],
] as const;

/** Leo's hat, scaled to a gallery: eight subagents running, a test run, seven waits and eleven plain
 *  commands; behind them 40 done, 5 stopped and 9 failed (which leave the hat). */
const crowded = chat(
  [
    user("Keep every lane moving and land what is green", 190),
    row(SUBAGENTS, 190, {
      subagents: [
        ...RUNNING_TASKS.map(([task, said], index) =>
          agent(task, 188 - index * 7, "running", { action: "Read", lastMessage: said }),
        ),
        ...Array.from({ length: 40 }, (_, index) => agent(`Finished check ${index + 1}`, 30, "completed")),
        ...Array.from({ length: 5 }, (_, index) => agent(`Stopped check ${index + 1}`, 20, "cancelled")),
        agent("Review nightly PR 41702", 6, "failed"),
        agent("List agent-chat render layers vs hq#9655", 5, "failed"),
        agent("Analyze Leo's 8.48 PM recording + latency", 5, "failed"),
        agent("ws-check backlog unstick", 4, "failed"),
        ...Array.from({ length: 5 }, (_, index) => agent(`Review cmux#4172${index}`, 4, "failed")),
      ],
    }),
    activity(
      [
        command("cmux-ci test --setup webviews -- bun test test/x.test.ts", "Run the tray tests", 30),
        ...Array.from({ length: 7 }, (_, index) =>
          command(`gh pr checks ${41700 + index} --watch`, `Wait for #${41700 + index}`, 60),
        ),
        ...Array.from({ length: 11 }, (_, index) =>
          command(`rg -n "TODO(${index})" src`, `Find the TODOs of pass ${index + 1}`, 50),
        ),
      ],
      60,
    ),
  ],
  { isWorking: true },
);

/** Three running, two done and one failed: a hat with room to spare. */
const few = chat(
  [
    user("Review the tray from both sides", 20),
    row(SUBAGENTS, 20, {
      subagents: [
        ...RUNNING_TASKS.slice(0, 3).map(([task, said], index) =>
          agent(task, 18 - index * 4, "running", { action: "Read", lastMessage: said }),
        ),
        agent("Find the screenshot", 9, "completed"),
        agent("Read the fold tests", 8, "completed"),
        agent("Bisect the flaky fold test", 7, "failed"),
      ],
    }),
  ],
  { isWorking: true },
);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const fold = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLElement>(".acpmux-running-tray [data-ended-fold] > button");

async function open(ctx: PlayContext): Promise<void> {
  await ctx.waitFor(() => head(ctx));
  if (head(ctx)!.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => fold(ctx));
}

function checkCollapsed(ctx: PlayContext, count: number): void {
  if (fold(ctx)?.getAttribute("aria-expanded") !== "false" || !fold(ctx)?.textContent?.includes(`${count} finished`))
    throw new Error(`Expected the disclosure for ${count} finished items`);
  if (ctx.document.querySelector(".acpmux-running-tray li[data-finished]"))
    throw new Error("Ended rows are visible with the disclosure closed");
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-ended",
  title: "Composer hat finished work",
  area: "Agent pane",
  height: 460,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx"],
  variants: {
    crowded: {
      note: "Eight agents are running. Forty-five finished items share one disclosure.",
      play: async (ctx) => {
        await open(ctx);
        checkCollapsed(ctx, 45);
      },
      snapshot: crowded,
    },
    "ended-open": {
      note: "Opening the disclosure shows the finished rows below the running work.",
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-running-tray [data-ended-fold] > button" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 45);
      },
      snapshot: crowded,
    },
    few: {
      note: "Three agents are running and two finished items share a disclosure.",
      play: async (ctx) => {
        await open(ctx);
        checkCollapsed(ctx, 2);
      },
      snapshot: few,
    },
  },
});
