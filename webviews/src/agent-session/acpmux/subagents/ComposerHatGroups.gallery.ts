// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's `groups` header (trayFoldHead.experiment.ts, trayHeadKinds.ts `trayHeadGroups`,
// HeadSummary.tsx) and its leading column (trayColumn.experiment.ts). Leo, 2026-11-24 00:18Z: "for one
// at least now the alignment becomes... maybe awkward? against the (currently fixing, ignore the
// outline) attachment + button. lucas raised that. ... the background command type delineation was my
// doing anyways. the simplest view is just... subagents. other background things. boom. waits, etc,
// they're just normal tool calls that are backgrounded instead of dozesns of possible different
// buttons. we can obviously keep the icons the stuff but... we can group them up more if we think it's
// much better looking that way."
//
// Two groups: subagents, then everything else backgrounded. In words while they fit ("3 subagents · 2
// tasks in background"), then shorter ("3 subagents · 2 tasks"), then each group's mark and number;
// a lone item reads its name. Waiting and failed follow only when they need the person. The lines
// under it keep every item's own mark. Compare the arms side by side, and the two columns against the
// composer's +, at 280, 400 and 900 px.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, user, tool } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { PLUS_PICKER } from "../composerSelectors";
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

/** Three subagents (one Codex), a dev server and a test watch; one subagent done, one failed. */
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

/** One background wait, alone: it reads its name. */
const loneCommand = chat(
  [
    user("Watch the nightly", 3),
    activity([command("gh run watch 41723867191 --exit-status", "Wait for the nightly run", 2.5)], 3),
  ],
  { isWorking: true },
);

/** One subagent, alone: its mark and its task. */
const loneAgent = chat(
  [
    user("Fix the staging VM", 4),
    row(SUBAGENTS, 4, { subagents: [agent("Fix staging chat VM never getting a machine", 3, "running")] }),
  ],
  { isWorking: true },
);

/** Fourteen subagents over three harnesses and six commands of four kinds: still two groups. */
const burst = chat(
  [
    user("Fan out over every package", 20),
    row(SUBAGENTS, 20, {
      subagents: Array.from({ length: 14 }, (_, index) =>
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

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const summary = (ctx: PlayContext) =>
  head(ctx)?.querySelector<HTMLElement>(".acpmux-running-tray__summary[data-summary]");

/** The groups' promises at whatever width the stage has. */
function groupsHold(ctx: PlayContext, kinds: readonly string[]): void {
  const header = head(ctx)!;
  const line = summary(ctx);
  if (!line) throw new Error("no summary header");
  if (/running/i.test(header.textContent ?? "")) throw new Error(`the header says running: ${header.textContent}`);
  const drawn = [
    ...line.querySelectorAll<HTMLElement>(":scope .acpmux-running-tray__summary-line > * > [data-kind]"),
  ].map((kind) => kind.dataset.kind ?? "");
  for (const kind of drawn)
    if (!kinds.includes(kind)) throw new Error(`the header draws ${kind}, only ${kinds.join(", ")} expected`);
  const time = header.querySelector<HTMLElement>(".acpmux-running-tray__time");
  if (time && time.scrollWidth > time.clientWidth + 0.5) throw new Error("the time is clipped");
}

/** In the `glyph` column the hat's first mark starts on the composer +'s ink (within a pixel). */
function columnHolds(ctx: PlayContext, column: "glyph" | "chip"): void {
  const mark = head(ctx)?.querySelector<HTMLElement>("[data-kind] svg, [data-kind] img, .acpmux-lineage__icon");
  const plus = ctx.document.querySelector<HTMLElement>(PLUS_PICKER);
  if (!mark || !plus) return;
  const plusBox = plus.getBoundingClientRect();
  const glyph = plus.querySelector("svg")?.getBoundingClientRect() ?? plusBox;
  const left = mark.getBoundingClientRect().left;
  const want = column === "glyph" ? glyph.left : plusBox.left;
  if (Math.abs(left - want) > 1.5) throw new Error(`the hat's mark starts at ${left}, the + ${column} at ${want}`);
}

const show = async (ctx: PlayContext) => {
  await ctx.waitFor(() => summary(ctx));
};

export default agentPaneEntry({
  id: "agent-pane.composer-hat-groups",
  title: "Composer hat groups: subagents and background",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 280, normal: 400, wide: 900 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/HeadSummary.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/trayColumn.experiment.ts",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: { definition: trayFoldHeadLook, script: [{ name: "show the header", run: (ctx) => show(ctx) }] },
  keywords: ["composer hat", "running tray", "background tasks", "subagents", "alignment"],
  variants: {
    mixed: {
      note: "The default: 3 subagents · 2 tasks in background, then the failed one's 1 in red; the done one needs nothing. Narrow, 3 subagents · 2 tasks, then the two marks and numbers. The hat's mark starts on the + glyph's column.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background", "failed"]);
        columnHolds(ctx, "glyph");
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "groups", "subagent-tray-column": "glyph" },
    },
    "mixed-chip-column": {
      note: "The same hat on the old column, the + chip's outer edge, to compare against the + (Lucas's point).",
      play: async (ctx) => {
        await show(ctx);
        columnHolds(ctx, "chip");
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "groups", "subagent-tray-column": "chip" },
    },
    "mixed-marks": {
      note: "The `group-marks` arm: the two groups as marks and numbers at every width; hover a group for its names.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background", "failed"]);
      },
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "group-marks", "subagent-tray-column": "glyph" },
    },
    "mixed-kinds-before": {
      note: "Before: the `summary` arm, a kind per command (subagents, servers, tests ...), on the chip column.",
      play: show,
      snapshot: mixed,
      experiments: { "subagent-tray-fold-head": "summary", "subagent-tray-column": "chip" },
    },
    "lone-command": {
      note: "One background wait: its name, never a bare 1.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["background"]);
      },
      snapshot: loneCommand,
      experiments: { "subagent-tray-fold-head": "groups", "subagent-tray-column": "glyph" },
    },
    "lone-subagent": {
      note: "One subagent: its mark and its task.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents"]);
      },
      snapshot: loneAgent,
      experiments: { "subagent-tray-fold-head": "groups", "subagent-tray-column": "glyph" },
    },
    burst: {
      note: "Fourteen subagents over three harnesses and six commands of four kinds: still 14 subagents · 6 tasks in background, never a dozen kinds.",
      play: async (ctx) => {
        await show(ctx);
        groupsHold(ctx, ["agents", "background"]);
      },
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "groups", "subagent-tray-column": "glyph" },
    },
    "burst-kinds-before": {
      note: "Before, on the same work: a kind per harness and per command kind.",
      play: show,
      snapshot: burst,
      experiments: { "subagent-tray-fold-head": "summary", "subagent-tray-column": "chip" },
    },
  },
});
