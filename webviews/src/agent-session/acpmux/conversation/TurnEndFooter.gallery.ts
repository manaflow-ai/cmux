// l10n-allow-file: gallery fixtures (sample prompts, tool output and agent errors), not shipped UI.
// Every finished turn ends on its footer row (TurnRows.tsx TurnFooter; G04): a turn that only ran
// tools copies their lines and the last call's output, and a turn that failed (an API error) keeps its
// row under the error card with the failed mark. Compare arms shows the `failed-turn-mark`
// experiment's three marks (failedTurnMark.experiment.ts); the reference is Claude desktop's row
// under a reply (claude/live/transcript-turn-footer-stats-row) and its error card's circled !
// (claude/live/status-subagent-failure-and-resume).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { failedTurnMark } from "./failedTurnMark.experiment";

const prompt = "Run the sidebar tests and fix what fails";
const apiError =
  "API Error: Request rejected (429) · This request would exceed your account's rate limit. Please try again later.";

const ranTests = (at: number) =>
  activity(
    [
      tool("bun test src/sidebar", "execute", "completed", {
        command: "bun test src/sidebar",
        description: "Ran the sidebar tests",
        output: "12 pass\n0 fail\nRan 12 tests across 3 files. [1.84s]\n",
        exitCode: 0,
      }),
    ],
    at,
  );

/// A turn that answered with one command and no words.
export const toolOnlyTurn = () => [
  user(prompt, 6),
  ranTests(5.9),
  summary(5.6, { status: "completed", durationMs: 24_000, toolCount: 1 }),
];

/// A turn that ran a command, then ended in an API error.
export const failedTurn = () => [
  user(prompt, 6),
  ranTests(5.9),
  summary(5.6, { status: "failed", durationMs: 41_000, toolCount: 1, error: apiError }),
];

/// A turn that failed before it ran or said anything: nothing to copy, the row keeps its mark.
const failedEmptyTurn = () => [user(prompt, 6), summary(5.9, { status: "failed", durationMs: 3_000, error: apiError })];

const rowAtRest = async (ctx: PlayContext) => {
  const find = () => ctx.document.querySelector(".acpmux-turnSummary .cv-turn-actions");
  await ctx.waitFor(find);
  const row = find();
  if (!row) throw new Error("The turn's footer row is missing");
  if (Number(getComputedStyle(row).opacity) < 1) throw new Error("The turn's footer row must show at rest");
};

/// A finished turn's row is hidden at rest and shows while the pointer is on its turn (cmux#55888,
/// Leo 2026-11-22: "claude hides buttons until you hover over the relevant area of a turn response"),
/// so the play points at the turn, then the row must show in full with its Copy.
const rowOnHover = async (ctx: PlayContext) => {
  const find = () => ctx.document.querySelector<HTMLElement>(".acpmux-turnSummary .cv-turn-actions");
  await ctx.waitFor(find);
  await ctx.hover({ selector: ".acpmux-turnSummary" });
  await ctx.waitFor(() => {
    const row = find();
    return row !== null && Number(getComputedStyle(row).opacity) >= 1;
  });
  const row = find();
  if (!row) throw new Error("The turn's footer row is missing");
  if (Number(getComputedStyle(row).opacity) < 1) throw new Error("The turn's footer row must show on hover");
};

const copyOnHover = async (ctx: PlayContext) => {
  await rowOnHover(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-turnSummary .cv-turn-actions button[aria-label='Copy']"));
};

const failedMarkShown = async (ctx: PlayContext) => {
  await rowAtRest(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-turnSummary .cv-turn-end-mark--failed"));
};

export default agentPaneEntry({
  id: "agent-pane.turn-end-footer",
  title: "Turn end footer",
  area: "Agent pane",
  height: 300,
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
    "agent-session/acpmux/conversation/turnCopy.ts",
  ],
  keywords: ["footer", "copy", "done", "failed", "error", "tool-only", "turn end"],
  variants: {
    "tool-only": {
      note: "A turn that only ran a command ends on its row, shown while the turn is hovered: Copy copies the command's line and its output.",
      snapshot: chat(toolOnlyTurn()),
      play: copyOnHover,
    },
    "tool-only-codex": {
      note: "The same turn in a Codex chat, folded under Worked for: its row stays under the closed line.",
      snapshot: chat(toolOnlyTurn(), { harness: "codex" }),
      play: copyOnHover,
    },
    "api-error": {
      note: "A turn that ran a command and then hit an API error: the error card, then the row with Copy and the failed mark.",
      snapshot: chat(failedTurn()),
      play: failedMarkShown,
    },
    "api-error-nothing-to-copy": {
      note: "A turn that failed before it did anything: no Copy, but the row keeps the failed mark.",
      snapshot: chat(failedEmptyTurn()),
      play: failedMarkShown,
    },
    "reply-then-tool-only": {
      note: "A replied turn, then a tool-only turn: both end on their rows, at the same 8 under their last line.",
      snapshot: chat([
        user("What does the sidebar test cover?", 9),
        assistant("It covers drag, drop and the pinned section.", 8.8),
        summary(8.7, { status: "completed", durationMs: 6_000 }),
        ...toolOnlyTurn(),
      ]),
      play: copyOnHover,
    },
  },
  experiment: {
    definition: failedTurnMark,
    // The failed turn's row at rest: its mark shows without a pointer.
    script: [{ name: "at rest", run: async () => {} }],
  },
});
