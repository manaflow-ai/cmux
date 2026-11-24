// l10n-allow-file: gallery fixtures, not shipped UI.
// The running turn's live line under a burst of calls (gallery/fixtures/LiveLineBurstStage.tsx; Leo,
// 2026-11-24: "the sending messages in rapid succession is really bad looking. it's just your tool
// call/thinking glimmer text rapidly flickering up with very bad/nonexistent fade-in fade-out"). One
// scripted loop: one call, a burst of 30 changes in 2 s (a call, Thinking, a call, ...), messages sent
// one after another, a long command. Each look pins the live line's call entry wait (liveCallEntry.ts) and its
// hand-over look (conversation.css `data-live-swap`), so a recording of each shows the difference;
// `feather` is shipped.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { LiveLineBurstLook } from "../../../gallery/fixtures/LiveLineBurstStage";

/// Waits until the stage's loop clock passes `ms`.
const clockPast = (ms: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const text = ctx.document.querySelector('[data-stage="clock"]')?.textContent ?? "0";
    return Number.parseFloat(text) * 1000 >= ms;
  });
};

const look = (value: LiveLineBurstLook) => ({ look: value });

export default componentEntry<{ look?: LiveLineBurstLook }>({
  id: "agent-pane.live-line-burst",
  title: "Live line under a burst: 30 Thinking and tool-call changes in 2 s",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/liveCallEntry.ts#useLiveStatus",
    "agent-session/acpmux/rows/ThinkingRow.tsx#ThinkingRow",
    "agent-session/acpmux/conversation/Thinking.tsx#Thinking",
  ],
  load: () => import("../../../gallery/fixtures/LiveLineBurstStage").then((module) => module.LiveLineBurstStage),
  pane: true,
  height: 160,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    feather: {
      note: "Shipped: a call shows only once it has run 250 ms, so the burst leaves the line on Thinking, its shimmer running on; a longer call rolls in with its edges feathered, the words fading out above and in below.",
      props: look("feather"),
      play: clockPast(5_000),
    },
    before: {
      note: "Before: every call and every Thinking between rolls in at once with cut edges, each roll cut off by the next (the flicker).",
      props: look("before"),
      play: clockPast(5_000),
    },
    "entry-roll": {
      note: "The call entry wait alone: no flicker through the burst, the rolls' edges still cut.",
      props: look("entry-roll"),
      play: clockPast(5_000),
    },
    cross: {
      note: "The call entry wait with a cross-fade in place of the roll (`data-live-swap=cross`).",
      props: look("cross"),
      play: clockPast(5_000),
    },
    reduced: {
      note: "Reduced motion: no roll, the words change at once; quick calls still never show.",
      props: look("reduced"),
      play: clockPast(5_000),
    },
  },
});
