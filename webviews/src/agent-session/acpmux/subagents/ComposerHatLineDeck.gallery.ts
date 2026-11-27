// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The one-line composer hat's marks (hatLine.experiment.ts, HatHeadDeck.tsx,
// hatHeader.css). Lawrence, 2026-11-20: "ui for opening subagents is very confusing". Leo: "we need to
// be able to like thumb through them like a Rolodex or whatever at the top ... you hover over it, and
// then on each one, it's like there's a slight pop and something ... perhaps the text itself maybe
// changes like on the top of the composer hat". Every arm over three and eight running lines, at rest
// and thumbed.
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

/// Leo's screenshot (2026-11-27, ask-b6fc7a81c2): fourteen subagents and six background commands, so
/// the deck shows eight marks and "+12 more", with the header open and its panel button showing.
const FOURTEEN: readonly Subagent[] = [
  ...AGENTS,
  ...AGENTS.map((agent, index) => ({
    ...agent,
    id: `${agent.id}-again`,
    task: `${agent.task}, second pass`,
    startedAt: minutesAgo(index + 1),
  })),
];
const TWENTY = chat([
  user("Fan the review out and keep the checks running while I look", 12),
  row(SUBAGENTS, 12, { subagents: [...FOURTEEN] }),
  activity(
    [
      command("bun test --watch", "Watch the tests", 8),
      command("bun run dev", "Run the dev server", 8),
      command("cargo watch -x check", "Check the daemon", 7),
      command("tail -f logs/app.log", "Follow the app log", 6),
      command("bun run gallery", "Run the gallery", 5),
      command("bun run typecheck --watch", "Typecheck", 4),
    ],
    11,
  ),
  assistant("The reviewers keep running in the background.", 1),
  summary(1, { status: "completed", durationMs: 600_000, toolCount: 3 }),
]);

/// Each variant pins the one line and its arm, so a later default never changes what it shows.
const pins = (arm: HatLineArm) => ({ "subagent-tray-fold-head": "line", "composer-hat-line-deck": arm });

const MARK = (n: number) => `.acpmux-hat-deck__mark:nth-child(${n})`;
const folded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
};
/// The pointer on the first mark, then run along to the `n`th: the line names that one.
const thumbedTo = (n: number) => async (ctx: PlayContext) => {
  await folded(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(MARK(n)));
  await ctx.hover({ selector: MARK(1) });
  await ctx.hover({ selector: MARK(n) });
  await ctx.waitFor(() => ctx.document.querySelector(`${MARK(n)}[data-peeked]`));
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
      { name: "the pointer on the second mark", run: thumbedTo(2) },
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
    "trail-thumb-eight": {
      note: "The pick, thumbed to the fifth mark: it pops, the line reads that subagent's name and latest step; a click opens it.",
      play: thumbedTo(5),
      snapshot: EIGHT,
      experiments: pins("trail"),
    },
    "trail-twenty-open": {
      note: "Leo's case (ask-b6fc7a81c2): fourteen subagents and six commands, opened. The words turn ink, never the accent, with no chip; the panel button sits at the row's end, clear of \"+12 more\".",
      play: async (ctx: PlayContext) => {
        await folded(ctx);
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__open"));
      },
      snapshot: TWENTY,
      experiments: pins("trail"),
    },
    "lead-thumb-eight": {
      note: "Marks leading, thumbed to the fifth.",
      play: thumbedTo(5),
      snapshot: EIGHT,
      experiments: pins("lead"),
    },
    "cards-thumb-eight": {
      note: "Fanned cards, the pointer on the fifth card: it flips to the front and names its line.",
      play: thumbedTo(5),
      snapshot: EIGHT,
      experiments: pins("cards"),
    },
  },
});
