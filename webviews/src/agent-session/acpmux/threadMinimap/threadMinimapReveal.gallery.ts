// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { threadMinimapReveal } from "./reveal.experiment";

const rows = Array.from({ length: 18 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next part of the plan`, 200 - index * 2),
  assistant(
    `Part ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height.`,
    199.8 - index * 2,
  ),
  summary(199.6 - index * 2, { status: "completed" }),
]).flat();

// Leo, 2026-11-22: "the scroll rail is slightly too sensitive to stuff when at small sizes ... there's a
// lot of awkwardness when you try to e.g. copy text along this area". Three arms (reveal.experiment.ts)
// across the quarter, third and half split widths, each with the three gestures that matter: a sweep past
// the edge, a selection drag that runs along it, and a deliberate rest on it.
export default agentPaneEntry({
  id: "agent-pane.thread-minimap-reveal",
  title: "Prompt rail reveal intent",
  area: "Agent pane",
  height: 640,
  // quarter, third and half split widths (WidthName keys: the URL takes only narrow|normal|wide, and a px
  // width under 240 is clamped).
  widths: { narrow: 160, normal: 220, wide: 320 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapReveal,
    script: [
      {
        name: "drag a selection along the edge",
        run: async (ctx) => {
          await ctx.pointer.down({ selector: ".cv-user__bubble" });
          await ctx.pointer.move({ selector: ".acpmux-minimap__strip" });
          await ctx.pointer.up({ selector: ".acpmux-minimap__strip" });
        },
      },
      { name: "rest on the edge", run: (ctx) => ctx.hover({ selector: ".acpmux-minimap__strip" }) },
    ],
  },
  variants: {
    resting: {
      note: "The rail at rest beside the text.",
      snapshot: chat(rows, { title: "Prompt rail at rest" }),
    },
    "drag-along-edge": {
      note: "A press in the text, then the pointer into the edge strip: the rail stays out of the drag (no reveal, no widening, no card).",
      snapshot: chat(rows, { title: "Selection drag along the rail" }),
      play: async (ctx) => {
        await ctx.pointer.down({ selector: ".cv-user__bubble" });
        await ctx.pointer.move({ selector: ".acpmux-minimap__strip" });
      },
    },
    "rest-reveal": {
      note: "A resting pointer on the edge reveals the rail and its preview.",
      snapshot: chat(rows, { title: "Prompt rail revealed by a rest" }),
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-minimap__strip" });
        await ctx.hover({ selector: '[data-tick="0"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
  },
});
