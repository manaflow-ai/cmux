// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { setBookmarkTransport } from "./bookmarks";
import { threadMinimapMark } from "./mark.experiment";

// The compact rail's four tick states (rest, the lit band, hovered, bookmarked) at each bookmarked
// look mark.experiment.ts keeps, side by side in the compare view: grey at 55%, grey at 70% (the
// default), the dot only, and the full brightness the rail drew before. Synthetic prompts only.
// Leo 2026-10-25: "when I bookmark something, it shouldn't be just at the full brightness ... It
// should be, like, grayed out. That's how ChatGPT does it".
// The gallery has no acpmux: this entry's chat answers with prompts 3 and 12 marked. Set when a state
// plays (the page's one transport is shared with the other minimap entries), and it keeps their
// toggles as acpmux would.
const marks = new Map<string, Set<number>>();
const marksOf = (sessionId: string) => marks.get(sessionId) ?? new Set([3, 12]);
const showMarks = () =>
  setBookmarkTransport({
    get: async (sessionId) => ({ sessionId, bookmarks: [...marksOf(sessionId)] }),
    set: async (sessionId, seq, bookmarked) => {
      const next = new Set(marksOf(sessionId));
      if (bookmarked) next.add(seq);
      else next.delete(seq);
      marks.set(sessionId, next);
      return { sessionId, bookmarks: [...next] };
    },
  });
const rows = Array.from({ length: 18 }, (_, index) => [
  // Rows `user-<seq>`, as acpmux names a prompt, so a bookmark can name it.
  user(`Prompt ${index + 1}: check the next step of the plan`, 300 - index * 2, { id: `user-${index + 1}` }),
  assistant(
    `Step ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    299.8 - index * 2,
  ),
  summary(299.6 - index * 2, { status: "completed" }),
]).flat();
/// Tick 11 is prompt 12, bookmarked.
const MARKED_TICK = '[data-tick="11"][data-bookmarked]';

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-mark",
  title: "Thread minimap tick states",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapMark,
    script: [
      {
        name: "scroll mid-thread",
        run: async (ctx) => {
          showMarks();
          await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
          await ctx.waitFor(() => ctx.document.querySelector(MARKED_TICK));
        },
      },
      { name: "hover the bookmarked prompt", run: (ctx) => ctx.hover({ selector: MARKED_TICK }) },
    ],
  },
  variants: {
    states: {
      note: "At rest mid-thread: resting ticks grey (40%), the prompts on screen lit (75%), prompts 3 and 12 bookmarked: their tick and dot the resting grey a step brighter, never the text at full brightness.",
      snapshot: chat(rows, { title: "Tick states at rest" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        showMarks();
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector(MARKED_TICK));
      },
    },
    "bookmark-hovered": {
      note: "The pointer on bookmarked prompt 12: its tick and dot turn the text at full brightness at once, and the rail magnifies around it.",
      snapshot: chat(rows, { title: "A hovered bookmarked tick" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        showMarks();
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector(MARKED_TICK));
        await ctx.hover({ selector: MARKED_TICK });
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="11"][data-tone="active"]'));
      },
    },
    "rest-hovered": {
      note: "The pointer on prompt 15, not bookmarked: it turns the text and grows no dot; bookmarked prompt 12 stays grey beside it.",
      snapshot: chat(rows, { title: "A hovered resting tick" }),
      play: async (ctx) => {
        if (!ctx.document.querySelector('[data-tick="8"]')) return;
        showMarks();
        await ctx.scroll({ selector: ".acpmux-scroll" }, 700);
        await ctx.waitFor(() => ctx.document.querySelector(MARKED_TICK));
        await ctx.hover({ selector: '[data-tick="14"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-tick="14"][data-tone="active"]'));
      },
    },
  },
});
