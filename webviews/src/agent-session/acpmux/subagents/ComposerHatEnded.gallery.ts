// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat with a coordinator's load on it (SubagentTray.tsx), as Leo saw it on 2026-11-12:
// "if these failed, I don't know why they still show up ... I feel like there are just way too many
// right now ... why are there ellipses going so fast? Like they get truncated and cut off so soon."
// Its header read "33 subagents running · 1 test run · 7 waits · 11 commands · 292 done · 25 sto…",
// five failed lines stood in the open list, and titles cut right after their first words with half the
// row empty. Failed lines now leave the hat at once (runningTray.ts `endedInFailure`, App.tsx). Here:
// - what still ended (done, stopped) is one "N finished" line under what runs, which opens to its
//   lines (`EndedFold`); the open list shows what still runs;
// - the header counts what runs, then the commands, waits and plain commands last, and drops whole
//   counts from the end when its row is full (`HeadParts`), never "25 sto…";
// - a line's title runs to its time; what it does now takes the rest and cuts at the row's edge.
// Every variant renders at the default width and at 360px (narrow).
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

/** No ended line among the lines until the "N finished" line opens, and no count cut mid-word. */
function checkFolded(ctx: PlayContext): void {
  if (ctx.document.querySelector(".acpmux-running-tray li[data-finished]"))
    throw new Error("an ended line shows while the finished line is folded");
  const parts = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__parts");
  if (!parts) throw new Error("the header's counts are not whole parts");
  const top = parts.getBoundingClientRect().top;
  for (const part of parts.querySelectorAll<HTMLElement>(".acpmux-running-tray__part")) {
    const box = part.getBoundingClientRect();
    if (box.top > top + 1) continue; // wrapped away whole
    const words = part.querySelector<HTMLElement>(".acpmux-tick > span:last-child");
    if (words && words.scrollWidth > words.clientWidth + 1 && part !== parts.firstElementChild)
      throw new Error(`a count is cut: ${part.textContent}`);
  }
  // A wide hat: every running line's title is whole, and what it does now starts after it (it was one
  // box the row's ellipsis replaced at once: "Base reds: clippy + #41472…").
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  if (tray.getBoundingClientRect().width < 600) return;
  for (const line of tray.querySelectorAll<HTMLElement>(
    'li:not([data-finished]) .acpmux-agent-line[data-status="running"]',
  )) {
    const name = line.querySelector<HTMLElement>(".acpmux-summary-agent__name")!;
    if (name.scrollWidth > name.clientWidth + 1) throw new Error(`a title is cut: ${name.textContent}`);
    const latest = line.querySelector<HTMLElement>(".acpmux-agent-line__latest-inline");
    if (latest && latest.getBoundingClientRect().width < 40)
      throw new Error(`no room for the step after ${name.textContent}`);
  }
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-ended",
  title: "Composer hat: what ended folds to one line, counts drop whole, titles run to the time",
  area: "Agent pane",
  height: 460,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/AgentLine.tsx",
  ],
  variants: {
    crowded: {
      note: 'Leo\'s hat, open: eight running lines and one "45 finished" line under them (the 9 failed left the hat). The header says "8 subagents running · 1 test run · 7 waits · 11 commands" as far as the row holds, dropping whole counts from the end; no done or stopped count, no "sto…". Each line\'s title runs to its time and what it does now cuts at the row\'s edge.',
      play: async (ctx) => {
        await open(ctx);
        checkFolded(ctx);
        if (fold(ctx)!.textContent !== "45 finished") throw new Error(`the ended line: ${fold(ctx)!.textContent}`);
      },
      snapshot: crowded,
    },
    "ended-open": {
      note: 'The same hat with its "45 finished" line opened: the ended lines come under it and the list scrolls; one more click folds them back.',
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-running-tray [data-ended-fold] > button" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 45);
      },
      snapshot: crowded,
    },
    few: {
      note: 'Three running, two done and one failed (which left): "3 subagents running" heads, and "2 finished" is the one line under the three.',
      play: async (ctx) => {
        await open(ctx);
        checkFolded(ctx);
        const words = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (words !== "3 subagents running") throw new Error(`the header: ${words}`);
      },
      snapshot: few,
    },
    folded: {
      note: "Folded, the header names the longest-running work as before; the hat is one line over the composer.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx));
      },
      snapshot: crowded,
    },
  },
});
