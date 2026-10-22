// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

/// Eighteen prompts, as the Codex reference thread has, each with a two-paragraph reply.
const rows = Array.from({ length: 18 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next part of the plan`, 200 - index * 2),
  assistant(
    `Part ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    199.8 - index * 2,
  ),
  summary(199.6 - index * 2, { status: "completed" }),
]).flat();

// A narrow pane (Leo 2026-10-22: "and when the horizontal space shrinks too far it disapperas... idk
// i dont like that... we can maybe have a more minimal looking thing when not hovered but..."). Every
// width here starts the chat column less than 48 px in, where the rail used to hide.
export default agentPaneEntry({
  id: "agent-pane.thread-minimap-narrow",
  title: "Thread minimap, narrow pane",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 320, normal: 360, wide: 600 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    rest: {
      note: "At rest mid-thread in a narrow pane: a minimal rail inside the 18 px page edge, 4 px ticks left of the text, the prompts on screen brighter. Before, the rail hid at these widths.",
      snapshot: chat(rows, { title: "Thread minimap, narrow, at rest" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail[data-narrow]:not([data-expanded])"));
      },
    },
    hover: {
      note: "Hovering prompt 8 in a narrow pane: the full wave on the hover cards' glass over the text, row 8 at 26 px and its neighbors 20, 14 and 10 px, and the preview card 250 ms later. Leaving the rail puts it back to the minimal strip.",
      snapshot: chat(rows, { title: "Thread minimap, narrow, hovered" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        // The resting strip is 12 px wide: point at the tick's own line, inside it, as a person would.
        await ctx.hover({ selector: '[data-tick="8"] .acpmux-minimap__bar' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail[data-expanded]"));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
  },
});
