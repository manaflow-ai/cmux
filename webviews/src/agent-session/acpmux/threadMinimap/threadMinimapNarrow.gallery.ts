// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const rows = Array.from({ length: 18 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next part of the plan`, 200 - index * 2),
  assistant(
    `Part ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    199.8 - index * 2,
  ),
  summary(199.6 - index * 2, { status: "completed" }),
]).flat();

/// Gallery-only spacing comparison. The product always renders the chosen 4 px gutter; the two
/// alternatives move the same rail left after layout so the review can compare the padding loss at
/// wide, Session Info and narrow widths without adding a setting to the app.
const withGap = (gap: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)"));
  const rail = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
  const row = ctx.document.querySelector<HTMLElement>(".acpmux-row");
  if (!rail || !row) return;
  const frame = rail.offsetParent?.getBoundingClientRect();
  if (!frame) return;
  const target = Math.max(0, row.getBoundingClientRect().left - frame.left - rail.getBoundingClientRect().width - gap);
  rail.style.left = `${target}px`;
};
const gapPlay = withGap(4);

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-narrow",
  title: "Thread minimap gutter variants",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 780, normal: 1040, wide: 1600 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: {
    "gap-4-chosen": {
      note: "Chosen. The rail keeps its full 36 px look and sits 4 px from the transcript at rest; it sheds its spare gutter first as Session Info narrows the chat.",
      snapshot: chat(rows, { title: "Thread minimap, 4 px chosen gutter" }),
      play: gapPlay,
    },
    "gap-8": {
      note: "Alternative: an 8 px rail-to-text gutter, compared at wide, Session Info and narrow widths.",
      snapshot: chat(rows, { title: "Thread minimap, 8 px gutter alternative" }),
      play: withGap(8),
    },
    "gap-12": {
      note: "Alternative: a 12 px rail-to-text gutter, kept here to show the extra padding Leo rejected.",
      snapshot: chat(rows, { title: "Thread minimap, 12 px gutter alternative" }),
      play: withGap(12),
    },
  },
});
