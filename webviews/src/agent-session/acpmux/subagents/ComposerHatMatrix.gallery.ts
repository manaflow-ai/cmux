// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's width x state matrix. Leo, 2026-11-23: "my subagents idea displaying like that
// clearly didn't really work. because this is unusable at low widths. which is common. ... likewise,
// the timer."; "clearly, you guys haven't thought through and viewed all possible scenarios".
//
// Every state the dock can be in under the hat (nothing running, a grown composer, subagents and
// commands, a lone timed command, all of them at once with a grown composer) at 320 px, 390 px
// (a phone) and 590 px (an iPad split); ComposerHatTally.gallery.ts holds 280, 400 and 900. Each
// cell's play checks the tally's promises and the dock's: no words, no ellipsis, kinds whole or
// gone, the time never clipped, the hat above the composer, the buttons on its bottom edge.
import { agentPaneEntry } from "../../../gallery/format";
import {
  burst,
  dockHolds,
  GROWN_DRAFT,
  head,
  idle,
  lone,
  mixed,
  tallyHolds,
} from "../../../gallery/fixtures/composerHat";
import type { PlayContext } from "../../../gallery/play";
import { MODEL_PICKER } from "../composerSelectors";
import { trayFoldHeadLook } from "./trayFoldHead.experiment";

const TALLY = { "subagent-tray-fold-head": "tally" } as const;
const tally = (ctx: PlayContext) =>
  ctx.waitFor(() => head(ctx)?.querySelector(".acpmux-running-tray__kinds[data-tally]"));
const composer = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));

export default agentPaneEntry({
  id: "agent-pane.composer-hat-matrix",
  title: "Composer hat matrix: every dock state at phone, split and narrow widths",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 320, normal: 390, wide: 590 },
  anchors: [{ selector: ".acpmux-composer" }],
  keywords: ["composer hat", "tally", "matrix", "narrow", "phone", "iPad split", "grown composer"],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadKinds.ts",
    "agent-session/acpmux/subagents/subagents.css",
    "agent-session/acpmux/Composer.tsx",
  ],
  experiment: {
    definition: trayFoldHeadLook,
    script: [{ name: "show the dock", run: composer }],
  },
  variants: {
    empty: {
      note: "Nothing ongoing: no hat, the composer alone at one line.",
      play: async (ctx) => {
        await composer(ctx);
        if (head(ctx)) throw new Error("nothing runs, so there is no hat");
        dockHolds(ctx, MODEL_PICKER);
      },
      snapshot: idle,
      experiments: TALLY,
    },
    grown: {
      note: "An eight-line draft, nothing ongoing: the composer grows, its buttons stay on the bottom edge.",
      play: async (ctx) => {
        await composer(ctx);
        dockHolds(ctx, MODEL_PICKER);
      },
      snapshot: idle,
      ready: { draft: GROWN_DRAFT },
      experiments: TALLY,
    },
    subagents: {
      note: "Two Claude and one Codex subagent, a server and a test run, one failed subagent: marks and numbers only.",
      play: async (ctx) => {
        await tally(ctx);
        tallyHolds(ctx, 2);
        dockHolds(ctx, MODEL_PICKER);
      },
      snapshot: mixed,
      experiments: TALLY,
    },
    timer: {
      note: 'One background command and its time: the time never clips, no "Running a command".',
      play: async (ctx) => {
        await tally(ctx);
        tallyHolds(ctx, 1);
        dockHolds(ctx, MODEL_PICKER);
      },
      snapshot: lone,
      experiments: TALLY,
    },
    everything: {
      note: "Twenty subagents over three harnesses, six commands and an eight-line draft at once: kinds that do not fit drop whole, the hat stays above the grown composer.",
      play: async (ctx) => {
        await tally(ctx);
        tallyHolds(ctx, 2);
        dockHolds(ctx, MODEL_PICKER);
      },
      snapshot: burst,
      ready: { draft: GROWN_DRAFT },
      experiments: TALLY,
    },
  },
});
