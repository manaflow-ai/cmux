// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { threadMinimapLit } from "./lit.experiment";

// The compact rail's lit band (the prompts on screen) at each brightness lit.experiment.ts keeps,
// side by side in the compare view: 60% (#22228), 70%, 75% (the default) and 85%, over resting ticks
// at 40% and a hovered tick at 100%. Synthetic prompts only.
const rowsOf = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Prompt ${index + 1}: check the next step of the plan`, 300 - index * 2),
    assistant(
      `Step ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
      299.8 - index * 2,
    ),
    summary(299.6 - index * 2, { status: "completed" }),
  ]).flat();
const rows = rowsOf(18);
/// Past the rail's room (64 rows or 70% of the window), so its list scrolls.
const long = rowsOf(70);

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-lit",
  title: "Thread minimap lit band",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapLit,
    script: [
      { name: "scroll mid-thread", run: (ctx) => ctx.scroll({ selector: ".acpmux-scroll" }, 700) },
      { name: "hover prompt 8", run: (ctx) => ctx.hover({ selector: '[data-tick="8"]' }) },
    ],
  },
  variants: {
    "mid-thread": {
      note: "Eighteen prompts at rest mid-thread: the prompts on screen lit over the resting ticks.",
      snapshot: chat(rows, { title: "Lit band mid-thread" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="4"][aria-current="true"]'));
      },
    },
    "at-the-end": {
      note: "Seventy prompts scrolled to the end: the rail's list at its end, the last prompts lit with no fade over them.",
      snapshot: chat(long, { title: "Lit band at the end" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="40"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 1_000_000);
        await ctx.waitFor(
          () =>
            !!ctx.document.querySelector('[data-tick="69"][aria-current="true"]') &&
            !ctx.document.querySelector(".acpmux-minimap__list[data-fade-bottom]"),
        );
      },
    },
    hovered: {
      note: "The pointer on prompt 3 mid-thread: the hovered tick at full brightness and magnified, and the prompts on screen still lit beside it (#22228 dimmed them back to rest).",
      snapshot: chat(rows, { title: "Lit band with the pointer on the rail" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="4"][aria-current="true"]'));
        await ctx.hover({ selector: '[data-tick="2"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail[data-hovering]"));
      },
    },
  },
});
