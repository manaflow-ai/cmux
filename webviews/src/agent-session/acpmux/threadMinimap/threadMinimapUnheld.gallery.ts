// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The prompt rail full length while only the recent prompts are loaded: the chat's count (the
// snapshot's `promptCount`) draws a tick for every prompt from the first frame, and loading older
// history only fills them in (Leo, 2026-11-03: "can it be bigger even without having all the prompts
// loaded? like it can read the count metadata right?" and "mostly i just don't like it when the thing
// shifts and whatnot trying to center itself"). Compare the three variants: the rail is the same box,
// and its ticks are in the same places, before, during and after history loads.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const TOTAL = 60;
const prompt = (n: number) => `Prompt ${n}: inspect the next part of the rollout`;
/// The last `held` turns, as the open page holds them; prompt n's row is `user-<n>`.
const heldRows = (held: number): AcpmuxRow[] =>
  Array.from({ length: held }, (_, index) => {
    const n = TOTAL - held + 1 + index;
    return [
      { ...user(prompt(n), 300 - n * 2), id: `user-${n}` },
      assistant(`Step ${n} checked.\n\nThe reply stays in the transcript.`, 299.8 - n * 2),
      summary(299.6 - n * 2, { status: "completed" }),
    ];
  }).flat();
/// The prompt index's rows for the prompts older than the last `held`.
const indexRows = (held: number): AcpmuxRow[] =>
  Array.from({ length: TOTAL - held }, (_, index) => ({ ...user(prompt(index + 1), 0), id: `user-${index + 1}` }));
/// The reader wheels the rail up to the oldest prompts, then points at one. Sixty prompts overflow the
/// rail's one height (#34666), which opens on the latest ones and draws only the ticks in its view
/// (tickWindow.ts), so an old prompt's tick is there only once the list is scrolled to it. The wheel
/// is what marks the rail as the reader's (`railBrowsing`), so it stays where they put it.
const pointAtOld =
  (tick: number): Play =>
  async (ctx) => {
    const list = ctx.find({ selector: ".acpmux-minimap__list" });
    list.dispatchEvent(new (ctx.document.defaultView!.WheelEvent)("wheel", { deltaY: -1, bubbles: true }));
    await ctx.scroll({ selector: ".acpmux-minimap__list" }, "top");
    await ctx.hover({ selector: `[data-tick="${tick}"]` });
  };

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-unheld",
  title: "Thread minimap: full length before history loads",
  area: "Agent pane",
  height: 720,
  widths: { normal: 1040 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    "count-only": {
      note: "Twelve of sixty prompts loaded and the index not answered: sixty ticks from the count. Hovering an unloaded prompt's tick shows the card with a blank line where its words go.",
      snapshot: chat(heldRows(12), { title: "Rail: count only", canLoadOlder: true, promptCount: TOTAL }),
      play: pointAtOld(4),
    },
    "mid-load": {
      note: "An older page landed: twenty-four held, the index still out. The same sixty ticks in the same places.",
      snapshot: chat(heldRows(24), { title: "Rail: mid-load", canLoadOlder: true, promptCount: TOTAL }),
      play: pointAtOld(4),
    },
    indexed: {
      note: "The prompt index answered: every tick has its words, and nothing moved. The card's words fade in where the blank line was.",
      snapshot: chat(heldRows(12), { title: "Rail: indexed", canLoadOlder: true, earlierPrompts: indexRows(12) }),
      play: pointAtOld(4),
    },
    "far-card-loading": {
      note: "A far unloaded prompt's card while the prompt index is out (the rail asks for it on this hover): one blank line where its words go, in the card's final place.",
      snapshot: chat(heldRows(12), { title: "Rail: far card loading", canLoadOlder: true, promptCount: TOTAL }),
      play: pointAtOld(2),
    },
    "far-card-loaded": {
      note: "The same far prompt's card once the index answered: its words, at the same spot, and a click lands on it.",
      snapshot: chat(heldRows(12), {
        title: "Rail: far card loaded",
        canLoadOlder: true,
        earlierPrompts: indexRows(12),
      }),
      play: pointAtOld(2),
    },
  },
});
