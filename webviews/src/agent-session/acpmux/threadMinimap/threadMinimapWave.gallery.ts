// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { threadMinimapWave } from "./wave.experiment";

// The compact rail's hover wave at each shape wave.experiment.ts keeps, side by side in the compare
// view: the zipper (the default), stepped by row (as before), a raised cosine reaching 4 rows or 5,
// and a bell. Leo 2026-11-03: "it doesn't feel as wave-y as chatgpt's", then "the in-between feels a
// bit strange and gooey i'd rather keep it per zipper rail thing", "chatgpt has an animation for when
// it shrinks" and "you guys kinda messed up the selected one being the center tallest one". The
// variants hold the pointer on a row and between rows, and hold the zipper's clock mid-sweep and
// mid-release (hoverWave.ts `__cmuxRailWaveClock`). Synthetic prompts only.
const rows = Array.from({ length: 24 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next step of the plan`, 300 - index * 2),
  assistant(
    `Step ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    299.8 - index * 2,
  ),
  summary(299.6 - index * 2, { status: "completed" }),
]).flat();

/// Hovers tick `index`, then moves the pointer `share` of a row further down, and waits for the wave
/// to come to rest there (the stepped arm has no wave and rests on the hover).
async function holdBetween(ctx: PlayContext, index: number, share: number) {
  hold(ctx, undefined);
  const tick = `[data-tick="${index}"]`;
  if (!ctx.document.querySelector(tick)) return;
  await ctx.hover({ selector: tick });
  const list = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const box = ctx.find({ selector: tick }).getBoundingClientRect();
  const view = ctx.document.defaultView!;
  const at = { clientX: box.left + 6, clientY: box.top + box.height * share, bubbles: true, pointerType: "mouse" };
  list.dispatchEvent(new view.PointerEvent("pointermove", at));
  await ctx.waitFor(() => {
    const rail = ctx.document.querySelector(".acpmux-minimap__rail");
    return rail?.getAttribute("data-wave-state") === "still" || !rail?.hasAttribute("data-wave");
  });
}

type Clocked = { __cmuxRailWaveClock?: () => number };
/// Holds the zipper's clock at `at` ms (undefined: the page's own clock again).
function hold(ctx: PlayContext, at: number | undefined) {
  const view = ctx.document.defaultView as unknown as Clocked;
  if (at === undefined) delete view.__cmuxRailWaveClock;
  else view.__cmuxRailWaveClock = () => at;
}
/// Two painted frames of the page, so the zipper's loop has drawn the held instant.
const frames = (ctx: PlayContext) =>
  new Promise<void>((resolve) => {
    const view = ctx.document.defaultView!;
    view.requestAnimationFrame(() => view.requestAnimationFrame(() => resolve()));
  });
/// On prompt `index` with the zipper's clock held at 0, then at rest a second later.
async function holdOn(ctx: PlayContext, index: number) {
  hold(ctx, 0);
  await ctx.hover({ selector: `[data-tick="${index}"]` });
  hold(ctx, 1000);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-minimap__rail[data-wave-state="still"]'));
}
/// A sweep from prompt 10 down to prompt 13, a row every 30 ms, held 30 ms after the last row.
async function midSweep(ctx: PlayContext) {
  await holdOn(ctx, 9);
  let at = 1000;
  for (const index of [10, 11, 12]) {
    at += 30;
    hold(ctx, at);
    await ctx.hover({ selector: `[data-tick="${index}"]` });
  }
  hold(ctx, at + 30);
  await frames(ctx);
}
/// The pointer leaving the rail from prompt 10, held 60 ms into the shrink.
async function midRelease(ctx: PlayContext) {
  await holdOn(ctx, 9);
  const tick = ctx.find({ selector: '[data-tick="9"]' });
  const view = ctx.document.defaultView!;
  const away = ctx.document.querySelector(".acpmux-scroll");
  tick.dispatchEvent(new view.PointerEvent("pointerout", { bubbles: true, relatedTarget: away, pointerType: "mouse" }));
  hold(ctx, 1060);
  await frames(ctx);
}

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-wave",
  title: "Thread minimap hover wave",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapWave,
    script: [{ name: "pointer between prompts 10 and 11", run: (ctx) => holdBetween(ctx, 9, 1) }],
  },
  variants: {
    "reference-lengths": {
      note: "Beside ChatGPT's rail hovered (Leo's capture, 2026-11-03): its hovered tick is the single longest at the bulge's centre, the rows either side stepping down alike, 52, 40, 28, 20 then 12 px in the 2x capture. The zipper on prompt 10 draws the same 26, 20, 14, 10 and 6 px.",
      snapshot: chat(rows, { title: "Zipper beside the reference" }),
      play: (ctx) => holdOn(ctx, 9),
    },
    "mid-sweep": {
      note: "The zipper mid-sweep from prompt 10 to 13, a row every 30 ms, held 30 ms after the last: prompt 13 already full length, the ticks behind it each still easing down to their own row's length, the ones ahead easing up.",
      snapshot: chat(rows, { title: "Zipper mid-sweep" }),
      play: midSweep,
    },
    "mid-release": {
      note: "60 ms after the pointer left the rail from prompt 10: every tick of the bulge still on its way back to rest, in proportion, instead of gone in a frame.",
      snapshot: chat(rows, { title: "Zipper mid-release" }),
      play: midRelease,
    },
    "on-a-row": {
      note: "The pointer on the middle of prompt 10: the bump peaks there at 26 px and falls off smoothly on both sides.",
      snapshot: chat(rows, { title: "Wave on a row" }),
      play: (ctx) => holdBetween(ctx, 9, 0.5),
    },
    "between-rows": {
      note: "The pointer on the line between prompts 10 and 11. The zipper draws prompt 11 (the row under it) longest; the cosine arms draw both alike, just under 26 px, the in-between Leo called gooey.",
      snapshot: chat(rows, { title: "Wave between rows" }),
      play: (ctx) => holdBetween(ctx, 9, 1),
    },
    "quarter-row": {
      note: "Mid-sweep, a quarter of a row past the middle of prompt 10: prompt 10 still longest, prompt 11 closer to it than prompt 9.",
      snapshot: chat(rows, { title: "Wave a quarter row on" }),
      play: (ctx) => holdBetween(ctx, 9, 0.75),
    },
  },
});
