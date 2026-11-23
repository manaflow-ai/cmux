// l10n-allow-file: sample transcript for the transcript thumb's near look.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { NEAR_ATTRIBUTE } from "../../../scrollers";
import { thumbMotion } from "./thumbMotion.experiment";

const snapshot = chat(
  Array.from({ length: 60 }, (_, index) => [
    user(`Check part ${index + 1} of the plan`, 120 - index * 2),
    assistant(`Part ${index + 1} is checked. The retry helper and its tests pass.`, 119 - index * 2),
  ]).flat(),
);

/// The pointer at the transcript's bar (scrollers.ts installScrollerProximity marks it so), held
/// until the thumb's fade there has settled.
const nearBar = async (ctx: PlayContext) => {
  const scroller = await (async () => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-scroll .acpmux-row"));
    return ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  })();
  await ctx.scroll({ selector: ".acpmux-scroll" }, scroller.scrollHeight / 2);
  scroller.setAttribute(NEAR_ATTRIBUTE, "");
  await ctx.waitFor(() => !scroller.style.getPropertyValue("--cmux-shown-scroller-ink"));
};

export default agentPaneEntry({
  id: "agent-pane.thumb-motion",
  title: "Transcript thumb near the pointer",
  area: "Agent pane",
  height: 600,
  covers: ["scrollers.ts", "agent-session/acpmux/conversation/thumbMotion.experiment.ts"],
  experiment: {
    definition: thumbMotion,
    script: [{ name: "Reach for the thumb", run: nearBar }],
  },
  variants: {
    "near-fade": {
      experiments: { "thumb-motion": "fade" },
      note: 'Leo, 2026-11-20: "the thumb needs to look better when i do stuff". The pointer at the bar: the thumb has faded in to the near ink and widened (the default); it fades back out as the pointer leaves.',
      snapshot,
      play: nearBar,
    },
    "near-thin": {
      experiments: { "thumb-motion": "thin" },
      note: "The same fade to the near ink, staying as thin as it is while scrolling.",
      snapshot,
      play: nearBar,
    },
    "near-instant": {
      experiments: { "thumb-motion": "instant" },
      note: "Before: the near look comes in one frame from nothing at rest, and goes in one frame.",
      snapshot,
      play: nearBar,
    },
  },
});
