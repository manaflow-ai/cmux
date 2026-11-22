// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../../gallery/play";

// The prompt rail's two ends follow one rule (model.ts railEdgeFades): an end fades while there is more
// past it and has a hard edge once the chat is scrolled all the way to that end (Leo, 2026-11-22: "if i
// scroll up in the scroll rail, the lower end should reflect that i'm not at the very bottom, and
// therefore have the same fade effect as the top does. likewise, when im at the top, it should def
// have the hard edge like when im at the bottom."). Each play waits for the fades its position owes.
const turn = (index: number, count: number) => {
  const minutes = 6 * (count - index);
  return [
    user(`Prompt ${index + 1}: check the next part of the rollout plan`, minutes),
    assistant(
      `Part ${index + 1} checked.\n\nThe reply has a second paragraph, so each turn has some height in the transcript and the chat scrolls.`,
      minutes - 0.2,
    ),
    summary(minutes - 0.4, { status: "completed" }),
  ];
};
const rows = (count: number) => Array.from({ length: count }, (_, index) => turn(index, count)).flat();
const LONG = 60;

const SCROLLER = { selector: ".acpmux-scroll" };
const LIST = ".acpmux-minimap__list";

/// The rail's list with exactly these fades, once it shows them.
const fades = (ctx: PlayContext, top: boolean, bottom: boolean) =>
  ctx.waitFor(() => {
    const list = ctx.document.querySelector(LIST);
    return !!list && list.hasAttribute("data-fade-top") === top && list.hasAttribute("data-fade-bottom") === bottom;
  });
const loaded = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(`[data-tick="${LONG - 1}"]`));
/// The scroller's offset `fromBottom` px above its end.
const aboveBottom = (ctx: PlayContext, fromBottom: number) => {
  const node = ctx.document.querySelector<HTMLElement>(SCROLLER.selector)!;
  return Math.max(0, node.scrollHeight - node.clientHeight - fromBottom);
};

const top: Play = async (ctx) => {
  await loaded(ctx);
  await ctx.scroll(SCROLLER, "top");
  await fades(ctx, false, true);
};
const nearTop: Play = async (ctx) => {
  await loaded(ctx);
  await ctx.scroll(SCROLLER, "top");
  await ctx.scroll(SCROLLER, 300);
  await fades(ctx, true, true);
};
const middle: Play = async (ctx) => {
  await loaded(ctx);
  await ctx.scroll(SCROLLER, "top");
  await ctx.scroll(SCROLLER, aboveBottom(ctx, 0) / 2);
  await fades(ctx, true, true);
};
const nearBottom: Play = async (ctx) => {
  await loaded(ctx);
  await ctx.scroll(SCROLLER, "bottom");
  await ctx.scroll(SCROLLER, aboveBottom(ctx, 300));
  await fades(ctx, true, true);
};
const bottom: Play = async (ctx) => {
  await loaded(ctx);
  await ctx.scroll(SCROLLER, "top");
  await ctx.scroll(SCROLLER, "bottom");
  await fades(ctx, true, false);
};
const short: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-tick="2"]'));
  await fades(ctx, false, false);
};

const long = (title: string) => chat(rows(LONG), { title });

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-ends",
  title: "Prompt rail ends: fade or hard edge by scroll position",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 720, normal: 1000, wide: 1400 },
  covers: [
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
    "agent-session/acpmux/threadMinimap/model.ts#railEdgeFades",
  ],
  variants: {
    top: {
      note: "Scrolled to the very top: a hard top edge, the foot fades over the prompts below.",
      snapshot: long("Prompt rail at the top"),
      play: top,
    },
    "near-top": {
      note: "300 px down from the top: the head starts to fade, as the foot does.",
      snapshot: long("Prompt rail near the top"),
      play: nearTop,
    },
    middle: {
      note: "Mid-thread: both ends fade.",
      snapshot: long("Prompt rail mid-thread"),
      play: middle,
    },
    "near-bottom": {
      note: "300 px up from the bottom, the last prompts still lit: the foot fades, since the chat has more below.",
      snapshot: long("Prompt rail just above the bottom"),
      play: nearBottom,
    },
    bottom: {
      note: "Scrolled to the very bottom: a hard foot, the head fades over the prompts above.",
      snapshot: long("Prompt rail at the bottom"),
      play: bottom,
    },
    short: {
      note: "A short chat that does not scroll: every prompt on the rail, hard edges at both ends.",
      snapshot: chat(rows(3), { title: "Prompt rail, a short chat" }),
      play: short,
    },
  },
});
