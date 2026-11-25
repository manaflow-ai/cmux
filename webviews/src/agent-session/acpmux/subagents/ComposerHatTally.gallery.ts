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
import { burst, head, lone, mixed, settled, tallyHolds, twelve } from "../../../gallery/fixtures/composerHat";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";

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
