// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const rows = Array.from({ length: 18 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next part of the plan`, 200 - index * 2),
  assistant(
    `Part ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    199.8 - index * 2,
  ),
  summary(199.6 - index * 2, { status: "completed" }),
]).flat();

const rightEdge = { "agentPane.display.rail.side": "right" };

// Three widths show the actual product geometry: wide inset, compressed rail, and an occluded rail
// with a permanent hover strip. No gallery code changes the rail's measured origin or visibility.
export default agentPaneEntry({
  id: "agent-pane.thread-minimap-narrow",
  title: "Pane-pinned prompt rail",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 160, normal: 800, wide: 1600 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    resting: {
      note: "Chosen pane-edge placement: wide (1600), compressed (800), and visually hidden with a live strip (160). The chat column never moves the rail.",
      snapshot: chat(rows, { title: "Pane-pinned prompt rail" }),
    },
    hovered: {
      note: "The narrow edge strip reveals a full usable rail over the text; its preview starts at the rail's right edge.",
      snapshot: chat(rows, { title: "Prompt rail revealed by hover" }),
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-minimap__strip" });
        await ctx.hover({ selector: '[data-tick="0"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
    focused: {
      note: "With eighteen real prompts, Tab and ArrowDown put keyboard focus on the third tick. The base has no outline; the fix shows its inset focus ring at every width.",
      snapshot: chat(rows, { title: "Prompt rail revealed by keyboard" }),
      play: async (ctx) => {
        await ctx.focus({ selector: '[data-tick="0"]' });
        await ctx.press("Tab");
        await ctx.waitFor(() => ctx.document.activeElement?.matches('[data-tick="1"]'));
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => ctx.document.activeElement?.matches('[data-tick="2"]:focus-visible'));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
    // Settings > Agent Chat > Prompt Rail Side, or the rail's right-click menu (railSide.ts).
    "right-resting": {
      note: "Moved to the right edge: the same pane-edge inset from that edge, ticks growing toward the text, and the narrow pane's live strip at the right edge.",
      snapshot: chat(rows, { title: "Prompt rail on the right edge" }),
      display: rightEdge,
    },
    "right-hovered": {
      note: "On the right edge the preview card opens on the rail's left: card.right == rail.left.",
      snapshot: chat(rows, { title: "Prompt rail on the right, hovered" }),
      display: rightEdge,
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-minimap__strip" });
        await ctx.hover({ selector: '[data-tick="0"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
  },
});
