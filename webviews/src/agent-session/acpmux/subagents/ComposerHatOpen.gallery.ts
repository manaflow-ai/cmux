// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// How a composer hat line opens what it stands for (SubagentTray.tsx `line`, hatOpen.experiment.ts).
// Lawrence, 2026-11-20: "ui for opening subagents is very confusing". Today one chevron means two
// things: a subagent's line opens its view, while a command's line expands in place with Open in
// terminal inside. Four arms side by side, each in a real pane over synthetic work: today; a hover
// Rolodex (a card flips up over the line under the pointer; the header's own marks are cmux #47923);
// the whole row opening with a chevron of its own for details; and today's lines with the hide control
// moved from the hat's top edge into the header.
import { agentPaneEntry } from "../../../gallery/format";
import { pinKindsHead } from "../../../gallery/fixtures/kindsHead";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { hatOpenLook } from "./hatOpen.experiment";
import { RUNNING_TRAY_LIST_LINE } from "./subagentSelectors";

const running = (task: string, minutes: number, action: string, harness?: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
  ...(harness ? { harness } : {}),
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
      running("Review the fold motion", 6, "Read trayMotion.tsx"),
      running("Audit the hat's columns against the composer", 4, "Grep tray-chevron-width"),
      running("Check the docs agree with the tray", 2, "Read running-tray.md", "codex"),
    ],
  }),
  activity([command("bun test --watch", "Watch the tests", 5)], 11),
  assistant("The reviewers and the test watcher keep running in the background.", 1),
  summary(1, { status: "completed", durationMs: 600_000, toolCount: 3 }),
]);

type Arm = keyof typeof hatOpenLook.arms;
/// Each variant pins its arm, so a later default never changes what it shows.
const pins = (arm: Arm) => ({ "composer-hat-open": arm });

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const LINE_BUTTON = `${RUNNING_TRAY_LIST_LINE} .acpmux-agent-line__button`;
const SECOND_LINE = ".acpmux-running-tray__list > li:nth-child(2) .acpmux-agent-line__button";
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
};
const expanded = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(RUNNING_TRAY_LIST_LINE));
};
/// The pointer on the second line: the Rolodex flips its card up; elsewhere the line lights.
const lineHovered = async (ctx: PlayContext) => {
  await expanded(ctx);
  await ctx.hover({ selector: SECOND_LINE });
};
/// The `rolodex` arm's card on the second line, after the first: the warm group flips at once.
const thumbed = async (ctx: PlayContext) => {
  await expanded(ctx);
  await ctx.hover({ selector: LINE_BUTTON });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-hat-peek"));
  await ctx.hover({ selector: SECOND_LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-hat-peek"));
};
/// The `row` arm's chevron, pressed: the line's details open under it, the line stays where it is.
const detailsOpen = async (ctx: PlayContext) => {
  await expanded(ctx);
  await ctx.click({ selector: ".acpmux-agent-line__disclose" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-agent-line__disclose[aria-expanded='true']"));
};
/// The `hide` arm's header button, under the pointer.
const hideHovered = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.hover({ selector: ".acpmux-running-tray__title" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__hide"));
  await ctx.hover({ selector: ".acpmux-running-tray__hide" });
};
/// The top-edge tuck, today, under the pointer, for comparison with `hide`.
const tuckHovered = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.hover({ selector: ".acpmux-running-tray__title" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__tuck"));
  await ctx.hover({ selector: ".acpmux-running-tray__tuck" });
};

export default pinKindsHead(
  agentPaneEntry({
    id: "agent-pane.composer-hat-open",
    title: "Composer hat: opening a subagent",
    area: "Agent pane",
    height: 560,
    widths: { narrow: 360 },
    anchors: [{ selector: ".acpmux-composer" }],
    covers: [
      "agent-session/acpmux/subagents/SubagentTray.tsx",
      "agent-session/acpmux/subagents/AgentLine.tsx",
      "agent-session/acpmux/subagents/hatOpen.experiment.ts",
      "agent-session/acpmux/subagents/hatOpen.css",
    ],
    experiment: {
      definition: hatOpenLook,
      script: [
        { name: "the hat open", run: expanded },
        {
          name: "the pointer on a line",
          run: async (ctx) => ctx.hover({ selector: SECOND_LINE }),
        },
      ],
    },
    variants: {
      "today-open": {
        note: "Today, open: every line ends in the same chevron, but a subagent's opens its view and the command's expands in place.",
        play: lineHovered,
        snapshot,
        experiments: pins("today"),
      },
      "today-tuck": {
        note: "Today's hide control: the tab hanging from the hat's top edge, over the resize rim.",
        play: tuckHovered,
        snapshot,
        experiments: pins("today"),
      },
      "rolodex-line": {
        note: "Hover Rolodex: the line under the pointer flips a card up with its whole task, state and latest step; a click on a subagent opens it.",
        play: thumbed,
        snapshot,
        experiments: pins("rolodex"),
      },
      "row-open": {
        note: "Row opens: every line, the command too, opens what it stands for; its chevron is a button of its own, lit alone.",
        play: lineHovered,
        snapshot,
        experiments: pins("row"),
      },
      "row-details": {
        note: "Row opens, chevron pressed: the line's whole task and latest step open under it, in place.",
        play: detailsOpen,
        snapshot,
        experiments: pins("row"),
      },
      "hide-head": {
        note: "Hide in the header: the hide button sits before the panel button and the chevron, shown while the pointer is on the hat; the top edge keeps only the resize rim.",
        play: hideHovered,
        snapshot,
        experiments: pins("hide"),
      },
    },
  }),
);
