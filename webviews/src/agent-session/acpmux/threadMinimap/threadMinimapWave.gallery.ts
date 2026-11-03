// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { ROW_PITCH } from "./model";
import { threadMinimapWave } from "./wave.experiment";

// The compact rail's hover wave at each shape wave.experiment.ts keeps, side by side in the compare
// view: stepped by row (as before), a raised cosine reaching 4 rows (the default) or 5, and a bell.
// Leo 2026-11-03: "it doesn't feel as wave-y as chatgpt's ... it doesn't feel smooth when you're
// hoving your mouse through it". The variants hold the pointer mid-sweep, between two rows, where the
// stepped fisheye snaps to one row and the wave splits the bump between both. Synthetic prompts only.
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
  const tick = `[data-tick="${index}"]`;
  if (!ctx.document.querySelector(tick)) return;
  await ctx.hover({ selector: tick });
  const list = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const box = ctx.find({ selector: tick }).getBoundingClientRect();
  const view = ctx.document.defaultView!;
  const at = { clientX: box.left + 6, clientY: box.top + ROW_PITCH * share, bubbles: true, pointerType: "mouse" };
  list.dispatchEvent(new view.PointerEvent("pointermove", at));
  await ctx.waitFor(() => {
    const rail = ctx.document.querySelector(".acpmux-minimap__rail");
    return rail?.getAttribute("data-wave-state") === "still" || !rail?.hasAttribute("data-wave");
  });
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
    "on-a-row": {
      note: "The pointer on the middle of prompt 10: the bump peaks there at 26 px and falls off smoothly on both sides.",
      snapshot: chat(rows, { title: "Wave on a row" }),
      play: (ctx) => holdBetween(ctx, 9, 0.5),
    },
    "between-rows": {
      note: "Mid-sweep, the pointer on the line between prompts 10 and 11: both draw alike, just under 26 px, with the bump centered between them.",
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
