// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The one-line composer hat's marks (hatLine.experiment.ts, HatHeadDeck.tsx,
// hatHeader.css). Lawrence, 2026-11-20: "ui for opening subagents is very confusing". Leo: "we need to
// be able to like thumb through them like a Rolodex or whatever at the top ... you hover over it, and
// then on each one, it's like there's a slight pop and something ... perhaps the text itself maybe
// changes like on the top of the composer hat". Every arm over three and eight running lines, at rest
// and pointed at: the sentence stays (Leo, 2026-11-27: "tdont think we should have this hover anymore
// it's really bad").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { hatLineLook, type HatLineArm } from "./hatLine.experiment";

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
  running("Audit the composer hat against the composer's grid", 9, "Read subagents.css", "claude"),
  running("Review the fold motion", 7, "Read trayMotion.tsx", "codex"),
  running("Check the docs agree with the tray", 6, "Read running-tray.md"),
  running("Port the history page to the new list virtualizer", 5, "Edit HistoryPage.tsx", "codex"),
  running("Find why the second launch is slower", 4, "Grep launchTiming", "claude"),
  running("Write the release notes", 3, "Read release-notes/next/WRITING.md"),
  running("Benchmark the transcript's streaming path", 2, "Run bench:stream", "codex"),
];

const snapshotOf = (agents: readonly Subagent[], withCommand: boolean) =>
  chat([
    user("Fan the review out and keep the checks running while I look", 12),
    row(SUBAGENTS, 12, { subagents: [...agents] }),
    ...(withCommand ? [activity([command("bun test --watch", "Watch the tests", 8)], 11)] : []),
    assistant("The reviewers keep running in the background.", 1),
    summary(1, { status: "completed", durationMs: 600_000, toolCount: 3 }),
  ]);

const THREE = snapshotOf(AGENTS.slice(0, 3), false);
const EIGHT = snapshotOf(AGENTS, true);

/// Each variant pins the one line and its arm, so a later default never changes what it shows.
const pins = (arm: HatLineArm) => ({ "subagent-tray-fold-head": "line", "composer-hat-line-deck": arm });

const MARK = (n: number) => `.acpmux-hat-deck__mark:nth-child(${n})`;
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
};
/// The pointer on the first mark, then run along to the `n`th: the words stay as they were (Leo,
/// 2026-11-27, on the hover that swapped them for that line's name: "tdont think we should have this
/// hover anymore it's really bad").
const pointedAt = (n: number) => async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(MARK(n)));
  await ctx.hover({ selector: MARK(1) });
  await ctx.hover({ selector: MARK(n) });
};

const arms: [HatLineArm, string][] = [
  ["trail", "Sentence, then marks (the pick)"],
  ["lead", "Marks, then sentence"],
  ["cards", "Fanned cards, then sentence"],
  ["words", "Words only (cmux#56287)"],
];

export default agentPaneEntry({
  id: "agent-pane.composer-hat-line-deck",
  title: "Composer hat: marks on the one line",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360, wide: 900 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/HatHeadDeck.tsx",
    "agent-session/acpmux/subagents/hatLine.experiment.ts",
    "agent-session/acpmux/subagents/hatHeader.css",
  ],
  experiment: {
    definition: hatLineLook,
    script: [
      { name: "folded", run: folded },
      { name: "the pointer on the second mark: the sentence stays", run: pointedAt(2) },
    ],
  },
  keywords: ["composer hat", "running tray", "subagents", "rolodex", "thumb", "hide"],
  variants: {
    ...Object.fromEntries(
      arms.flatMap(([arm, what]) => [
        [
          `${arm}-three`,
          {
            note: `${what}, three lines (Claude, Codex, the chat's own).`,
            play: folded,
            snapshot: THREE,
            experiments: pins(arm),
          },
        ],
        [
          `${arm}-eight`,
          {
            note: `${what}, eight lines (seven subagents, a command).`,
            play: folded,
            snapshot: EIGHT,
            experiments: pins(arm),
          },
        ],
      ]),
    ),
    "trail-pointer-eight": {
      note: "The pick, the pointer on the fifth mark: the sentence stays (Leo, 2026-11-27: no hover swap); a click opens that subagent.",
      play: pointedAt(5),
      snapshot: EIGHT,
      experiments: pins("trail"),
    },
    "lead-pointer-eight": {
      note: "Marks leading, the pointer on the fifth: the sentence stays.",
      play: pointedAt(5),
      snapshot: EIGHT,
      experiments: pins("lead"),
    },
    "cards-pointer-eight": {
      note: "Fanned cards, the pointer on the fifth card: the sentence stays.",
      play: pointedAt(5),
      snapshot: EIGHT,
      experiments: pins("cards"),
    },
  },
});
