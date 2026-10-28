// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { threadMinimapHeight } from "./height.experiment";

const rowsOf = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Prompt ${index + 1}: inspect the next part of the rollout`, 300 - index * 2),
    assistant(
      `Step ${index + 1} checked.\n\nThe reply stays in the transcript while the rail keeps its own height.`,
      299.8 - index * 2,
    ),
    summary(299.6 - index * 2, { status: "completed" }),
  ]).flat();

const medium = rowsOf(18);
const long = rowsOf(70);
const tall = rowsOf(260);

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-height",
  title: "Thread minimap height",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapHeight,
    script: [
      { name: "scroll mid-thread", run: (ctx) => ctx.scroll({ selector: ".acpmux-scroll" }, 700) },
      { name: "hover prompt 8", run: (ctx) => ctx.hover({ selector: '[data-tick="8"]' }) },
    ],
  },
  variants: {
    "eighteen-prompts": {
      note: "Eighteen prompts with a tall initial rail. Compare how much quiet vertical rail each height arm gives the thread before overflow.",
      snapshot: chat(medium, { title: "Thread minimap height: initial rail" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="4"][aria-current="true"]'));
        await ctx.hover({ selector: '[data-tick="8"]' });
      },
    },
    "seventy-prompts": {
      note: "Seventy prompts. Compare the maximum arms as they approach the cleared pane height and leave only the rail's own scroll for overflow.",
      snapshot: chat(long, { title: "Thread minimap height: long chat" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="40"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 3600);
        // Each arm reaches a different transcript landing row. The shared acceptance condition is
        // the thing this gallery compares: the rail list has more tick content than its viewport.
        await ctx.waitFor(() => {
          const list = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__list");
          return !!list && list.scrollHeight > list.clientHeight;
        });
      },
    },
    "tall-pane-caps": {
      note: "Two hundred sixty prompts in a tall pane. The four arms reach distinct row caps before the viewport clearance bound.",
      height: 2100,
      snapshot: chat(tall, { title: "Thread minimap height: distinct caps" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="200"]')) return;
        await ctx.waitFor(() => {
          const list = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__list");
          return !!list && list.scrollHeight > list.clientHeight;
        });
      },
    },
  },
});
