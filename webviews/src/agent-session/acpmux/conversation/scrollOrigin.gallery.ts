// l10n-allow-file: sample transcript for the scroll origin's host.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

// A chat long enough to scroll several viewports, in rows of mixed height.
const snapshot = chat(
  Array.from({ length: 60 }, (_, index) => [
    user(`Check part ${index + 1} of the retry plan`, 120 - index * 2),
    assistant(
      index % 3 === 0
        ? `Part ${index + 1} is checked. The retry helper backs off twice, then gives up and reports the last error to the caller.\n\nIts tests cover the timeout, the cancel and the success on the second try.`
        : `Part ${index + 1} is checked.`,
      119 - index * 2,
    ),
  ]).flat(),
);

/// The room held above the loaded rows and the sub-pixel scroll origin move the thread, never each
/// row nor the scroller: there, each page landing restyled every element of every mounted row.
const originOnThread: Play = async (ctx) => {
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller?.style.getPropertyValue("margin-top") || scroller?.style.getPropertyValue("--acpmux-scroll-origin"))
    throw new Error("the scroll origin is written on the scroller, which restyles every row under it");
  const room = Number(ctx.document.querySelector<HTMLElement>(".acpmux-spacer")?.dataset.olderRoom ?? 0);
  const first = ctx.document.querySelector<HTMLElement>(".acpmux-thread > .acpmux-row");
  if (room > 0 && first && parseFloat(first.style.top) >= room)
    throw new Error("the rows are placed under the older-history room one by one, not by the thread");
};

/// The reader wheels up `viewports` screens, a step a frame, as a trackpad does, then rests.
const wheelUp =
  (viewports: number): Play =>
  async (ctx) => {
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!scroller) throw new Error("no transcript scroller");
    const target = Math.max(0, scroller.scrollTop - scroller.clientHeight * viewports);
    while (scroller.scrollTop > target + 1) {
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -40, bubbles: true, cancelable: true }));
      scroller.scrollTop -= 40;
      scroller.dispatchEvent(new Event("scroll"));
      await new Promise((done) => requestAnimationFrame(() => done(undefined)));
    }
    let still = 0;
    let last = -1;
    await ctx.waitFor(() => {
      still = scroller.scrollTop === last ? still + 1 : 0;
      last = scroller.scrollTop;
      return still >= 3;
    });
    await originOnThread(ctx);
  };

export default agentPaneEntry({
  id: "agent-pane.scroll-origin",
  title: "Transcript scroll origin on the thread",
  area: "Agent pane",
  height: 700,
  covers: ["agent-session/acpmux/conversation/scrollCoordinates.ts", "agent-session/acpmux/VirtualTranscript.tsx"],
  variants: {
    latest: {
      note: "At the latest row: the rows draw as before; no scroll origin on the scroller.",
      snapshot,
      play: originOnThread,
    },
    "scrolled-up": {
      note: "Wheeled up two screens: the rows sit where they did, and the origin a landing keeps is on the thread only.",
      snapshot,
      play: wheelUp(2),
    },
    top: {
      note: "Wheeled to the top of the chat: the first prompt draws at the top, unmoved.",
      snapshot,
      play: wheelUp(200),
    },
  },
});
