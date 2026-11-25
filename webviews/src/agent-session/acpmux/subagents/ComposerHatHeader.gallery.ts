// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's top bar (hatHeader.experiment.ts, HatHeadDeck.tsx, hatHeader.css). Lawrence,
// 2026-11-20: "ui for opening subagents is very confusing". Leo: "we need to be able to like thumb
// through them like a Rolodex or whatever at the top ... you mouse over it, and then you can just go and
// go and go ... where would the hide button be?". Every arm over one, three and eight running lines
// (long tasks, Claude and Codex and the chat's own harness, a background command), folded, and thumbed;
// the hide arms with the pointer on the hat. Light and dark: the gallery's color scheme switch.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { hatHeaderLook, type HatHeaderArm } from "./hatHeader.experiment";

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

const AGENTS: readonly Subagent[] = [
  running(
    "Audit every column of the composer hat against the composer's own grid at narrow widths and large text",
    9,
    "Read subagents.css",
    "claude",
  ),
  running("Review the fold motion", 7, "Read trayMotion.tsx", "codex"),
  running("Check the docs agree with the tray", 6, "Read running-tray.md"),
  running(
    "Port the history page to the new list virtualizer and keep its scroll anchoring through a resize",
    5,
    "Edit HistoryPage.tsx",
    "codex",
  ),
  running("Find why the second launch is slower than the first", 4, "Grep launchTiming", "claude"),
  running("Write the release notes", 3, "Read release-notes/next/WRITING.md"),
  running("Benchmark the transcript's streaming path under a 10k-row chat", 2, "Run bench:stream", "codex"),
];

const snapshotOf = (agents: readonly Subagent[], withCommand: boolean) =>
  chat([
    user("Fan the review out and keep the checks running while I look", 12),
    row(SUBAGENTS, 12, { subagents: [...agents] }),
    ...(withCommand ? [activity([command("bun test --watch", "Watch the tests", 8)], 11)] : []),
    assistant("The reviewers keep running in the background.", 1),
    summary(1, { status: "completed", durationMs: 600_000, toolCount: 3 }),
  ]);

/// One line (a long task, so the header truncates it), three (Claude, Codex, the chat's own), eight
/// (seven subagents and a background command).
const ONE = snapshotOf(AGENTS.slice(0, 1), false);
const THREE = snapshotOf(AGENTS.slice(0, 3), false);
const EIGHT = snapshotOf(AGENTS, true);

/// Each variant pins its arm, so a later default never changes what it shows.
const pins = (arm: HatHeaderArm) => ({ "composer-hat-header": arm });

const MARK = (n: number) => `.acpmux-hat-deck__mark:nth-child(${n})`;
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
};
/// The pointer on the first mark, then thumbed along to the `n`th: the header names that line.
const thumbedTo = (n: number) => async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(MARK(n)));
  await ctx.hover({ selector: MARK(1) });
  await ctx.hover({ selector: MARK(n) });
  await ctx.waitFor(() => ctx.document.querySelector(`${MARK(n)}[data-peeked]`));
};
/// The pointer on the hat's words: the hide control's hover state.
const hatHovered = async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.hover({ selector: ".acpmux-running-tray__title" });
};

type Variant = {
  note: string;
  play: (ctx: PlayContext) => Promise<void>;
  snapshot: typeof ONE;
  experiments: Record<string, string>;
};
const SIZES = { one: ONE, three: THREE, eight: EIGHT } as const;
const SIZE_NOTE = {
  one: "one line (a long task)",
  three: "three lines (Claude, Codex, the chat's own)",
  eight: "eight lines (seven subagents, a command)",
} as const;

/// Every arm, folded, over one, three and eight lines.
function rest(arm: HatHeaderArm, what: string): Record<string, Variant> {
  return Object.fromEntries(
    (Object.keys(SIZES) as (keyof typeof SIZES)[]).map((size) => [
      `${arm}-${size}`,
      { note: `${what}, ${SIZE_NOTE[size]}.`, play: folded, snapshot: SIZES[size], experiments: pins(arm) },
    ]),
  );
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-header",
  title: "Composer hat: the top bar",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/HatHeadDeck.tsx",
    "agent-session/acpmux/subagents/hatHeader.experiment.ts",
    "agent-session/acpmux/subagents/hatHeader.css",
  ],
  experiment: {
    definition: hatHeaderLook,
    script: [
      { name: "folded", run: folded },
      { name: "the pointer on the second line's mark", run: thumbedTo(2) },
      { name: "thumbed to the fourth", run: thumbedTo(4) },
    ],
  },
  variants: {
    ...rest("today", "Today: the stacked marks and the leading names"),
    ...rest("strip", "Icon strip at rest: one harness icon per running line"),
    "strip-thumb-three": {
      note: "Icon strip, the pointer run from the first icon to the second: it pops, the others step back, and the header reads that line's name and latest step.",
      play: thumbedTo(2),
      snapshot: THREE,
      experiments: pins("strip"),
    },
    "strip-thumb-eight": {
      note: "Icon strip over eight (the command's terminal mark second), thumbed to the last: the header reads that line; the time and chevron hold their columns.",
      play: thumbedTo(8),
      snapshot: EIGHT,
      experiments: pins("strip"),
    },
    ...rest("cards", "Rolodex cards at rest: the running lines as a fanned deck"),
    "cards-thumb-three": {
      note: "Rolodex cards, the pointer on the second card: it flips to the front, the cards behind fan away, the header names it.",
      play: thumbedTo(2),
      snapshot: THREE,
      experiments: pins("cards"),
    },
    "cards-thumb-eight": {
      note: "Rolodex cards over eight, the pointer on the fifth card (the wheel thumbs the same way).",
      play: thumbedTo(5),
      snapshot: EIGHT,
      experiments: pins("cards"),
    },
    ...rest("eye", "Eye at the right: the icon strip, and the hide control as an eye-slash circle before the chevron"),
    "eye-hover": {
      note: "Eye at the right, the pointer on the hat: the circle is already there at rest, so nothing pops in.",
      play: hatHovered,
      snapshot: THREE,
      experiments: pins("eye"),
    },
    ...rest("pill", "Pill at the left: the icon strip, and the hide control as a glass pill leading the bar"),
    "pill-hover": {
      note: "Pill at the left, the pointer on the hat.",
      play: hatHovered,
      snapshot: THREE,
      experiments: pins("pill"),
    },
    ...rest("bar", "Slim bar on top: the icon strip under a slim full-width bar that hides (press) or resizes (drag)"),
    "bar-hover": {
      note: "Slim bar on top, the pointer on the hat: the bar lights and shows its eye-slash.",
      play: hatHovered,
      snapshot: THREE,
      experiments: pins("bar"),
    },
  },
});
