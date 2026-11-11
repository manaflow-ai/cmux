// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat's step line handing over (trayMotion.tsx `Tick` slide), after Leo's note of
// 2026-11-11: "the composer hat the way it switches between text is ugly bc it's too slow on the
// transitions and there's breif moments where it just looks like a blank tear that then switches".
// Three arms (hatParts.experiment.ts `hatStepLook`; view Compare arms): the roll (shipped), the
// fade-and-slide before it, and a plain swap.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatStepLook } from "./hatParts.experiment";

type Props = { start?: ComposerHatHeadState };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const latest = (ctx: PlayContext) =>
  ctx.document.querySelector(
    ".acpmux-running-tray__latest .acpmux-tick > span:last-child, .acpmux-running-tray__latest > span:last-child",
  )?.textContent ?? "";

export const composerHatStepScript = [
  {
    name: "one step hands over to the next",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("step"));
      await ctx.waitFor(() => latest(ctx) === "Read SubagentTray.tsx");
    },
  },
  {
    name: "a burst of steps: each lands at once while the last still moves",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("step"));
      await ctx.click(stage("step"));
      await ctx.click(stage("step"));
      await ctx.waitFor(() => latest(ctx) === "Bash");
    },
  },
];

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-step",
  title: "Composer hat: a step handing over",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/trayMotion.tsx"],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 240,
  experiment: { definition: hatStepLook, script: composerHatStepScript },
  variants: {
    running: {
      note: 'One subagent runs: press Next step to watch "Bash" hand over to its next step.',
      props: { start: "running" },
    },
    play: {
      note: "One step hands over, then three land back to back.",
      props: { start: "running" },
      play: async (ctx: PlayContext) => {
        for (const step of composerHatStepScript) await step.run(ctx);
      },
    },
  },
});
