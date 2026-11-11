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

/// The sub-pixel scroll origin is kept on the thread, its one reader, never on the scroller: there,
/// an inherited custom property, each page landing restyled every element of every mounted row.
const originOnThread: Play = async (ctx) => {
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller?.style.getPropertyValue("--acpmux-scroll-origin"))
    throw new Error("the scroll origin is written on the scroller, which restyles every row under it");
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
  covers: [
    "agent-session/acpmux/conversation/scrollCoordinates.ts",
    "agent-session/acpmux/conversation/conversation.css",
  ],
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
