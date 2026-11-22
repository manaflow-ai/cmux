// l10n-allow-file: gallery fixtures, not shipped UI.
// How a finished item ends in the composer hat (DoneMark.tsx), after Leo, 2026-11-07, on "Done · 8m
// 12s": "I just feel like there's something off about this ... I know that the thing is aligned, but it
// just doesn't look that... Great." Four arms (hatParts.experiment.ts `hatDoneLook`; view Compare arms):
// a check and the time (shipped), the old words, Done in the success colour, the time alone.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatDoneLook } from "./hatParts.experiment";

type Props = { start?: ComposerHatHeadState };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-done",
  title: "Composer hat: how a finished item ends",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/DoneMark.tsx"],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 240,
  experiment: {
    definition: hatDoneLook,
    script: [
      {
        name: "it finishes: the header ends in the done mark",
        run: async (ctx: PlayContext) => {
          await ctx.click(stage("finish"));
          await ctx.waitFor(() => Boolean(ctx.document.querySelector("[data-hat-done]")));
        },
      },
    ],
  },
  variants: {
    done: {
      note: "One subagent finished: its task, then the done mark and its total at the row's end; a click expands the hat.",
      props: { start: "done" },
    },
    "done-open": {
      note: "One finished, opened: the header counts it, and its line ends in the same done mark.",
      props: { start: "done" as const },
      play: async (ctx: PlayContext) => {
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-agent-line [data-hat-done]")));
      },
    },
  },
});
