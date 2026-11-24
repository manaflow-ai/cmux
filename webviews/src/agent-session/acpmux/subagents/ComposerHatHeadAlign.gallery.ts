// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat's folded header on one centre line (SubagentTray.tsx, subagents.css): each kind's
// mark, the counts, the time, the Background tasks button and the chevron. Leo, 2026-11-22, on "1
// subagent · 1 subagent done · 1 stopped   17h 4m 46s" over the composer: "now some of the icons are
// misaligned. chief among them is the little sidebar button. it's misaligned. well it's the background
// tasks." The header had grown to 34px (trayHeadHeight.experiment.ts `roomy`) while the panel button
// over it kept the lines' 28px row from the top, so its icon sat 3px above the row's centre. Then:
// "idk tho that might just be the switch over from one completing subagent to another": the header's
// counts change in place as one subagent finishes and the next starts; the time, the panel button and
// the chevron never move. Compare at 420px (a half split) and 900px with the width presets.
// test/composer-hat-head-align.test.ts measures every centre.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadAlignState } from "../../../gallery/fixtures/ComposerHatHeadAlignStage";
import { trayHeadHeightLook } from "./trayHeadHeight.experiment";

type Props = { start?: ComposerHatHeadAlignState };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const phase = (ctx: PlayContext, value: number) =>
  ctx.waitFor(() => ctx.document.querySelector(`[data-stage-phase="${value}"]`));
const headReady = (ctx: PlayContext) =>
  ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head .acpmux-running-tray__kind"));

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-head-align",
  title: "Composer hat header: icons on one centre line",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayHeadHeight.experiment.ts",
  ],
  load: () =>
    import("../../../gallery/fixtures/ComposerHatHeadAlignStage").then((module) => module.ComposerHatHeadAlignStage),
  pane: true,
  height: 320,
  widths: { narrow: 420, normal: 900 },
  // The header's right end holds still while its counts change.
  anchors: [{ selector: ".acpmux-running-tray__open" }, { selector: ".acpmux-running-tray__chevron" }],
  // Every header height keeps the row's controls on its centre line.
  experiment: { definition: trayHeadHeightLook, script: [{ name: "the folded header", run: (ctx) => headReady(ctx) }] },
  keywords: ["composer hat", "running tray", "background tasks", "alignment"],
  variants: {
    mixed: {
      note: "Leo's hat: one subagent runs, one is done, one was stopped; its kinds, the time, the Background tasks button and the chevron on the row's centre line.",
      props: { start: "mixed" },
      play: headReady,
    },
    between: {
      note: "Mid hand-over: the running one just finished and the next has not started. Only the counts change; the row and its right end stay put.",
      props: { start: "between" },
      play: headReady,
    },
    next: {
      note: "The next subagent runs: the counts change in place again.",
      props: { start: "next" },
      play: headReady,
    },
    handover: {
      note: "Played: the running subagent finishes, then the next starts. The panel button and the chevron never move (the anchors).",
      props: { start: "mixed" },
      play: async (ctx: PlayContext) => {
        await headReady(ctx);
        await ctx.click(stage("finish"));
        await phase(ctx, 1);
        await ctx.click(stage("next"));
        await phase(ctx, 2);
      },
    },
  },
});
