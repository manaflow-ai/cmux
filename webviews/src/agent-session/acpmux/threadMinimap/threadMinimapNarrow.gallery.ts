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

/// Gallery-only inset comparison. The production placement remains untouched; these plays are
/// exploratory edge positions for the pending railPlacement/useRailPlacement seam. The exact
/// choice is made from rendered gallery captures, not inferred from private-image scale.
const withInset = (inset: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)"));
  const rail = ctx.document.querySelector<HTMLElement>(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
  if (!rail) return;
  rail.style.left = `${inset}px`;
};

export const railInsetVariants = {
  "inset-current": {
    note: "Current product placement with no gallery override; this is the baseline for every inset comparison.",
    snapshot: chat(rows, { title: "Thread minimap, current placement" }),
  },
  "inset-4-lawrence-candidate": {
    note: "Exploratory 4 px pane-edge candidate informed by the supplied Lawrence crop; confirm the visual match in the rendered gallery.",
    snapshot: chat(rows, { title: "Thread minimap, 4 px inset candidate" }),
    play: withInset(4),
  },
  "inset-8-reference-candidate": {
    note: "Exploratory 8 px pane-edge candidate informed by the four rail references; confirm the visual match in the rendered gallery before selecting a production token.",
    snapshot: chat(rows, { title: "Thread minimap, 8 px inset candidate" }),
    play: withInset(8),
  },
  "inset-12-alternative": {
    note: "Exploratory 12 px pane-edge alternative, retained to show a looser edge step in the same harness.",
    snapshot: chat(rows, { title: "Thread minimap, 12 px inset alternative" }),
    play: withInset(12),
  },
  "inset-16-alternative": {
    note: "Exploratory 16 px pane-edge alternative, the widest comparison before the rail starts consuming the chat gutter.",
    snapshot: chat(rows, { title: "Thread minimap, 16 px inset alternative" }),
    play: withInset(16),
  },
} as const;

export const threadMinimapGalleryVariants = {
  "gap-4-chosen": {
    note: "Chosen. The rail keeps its full 36 px look and sits 4 px from the transcript at rest; it sheds its spare gutter first as Session Info narrows the chat.",
    snapshot: chat(rows, { title: "Thread minimap, 4 px chosen gutter" }),
    play: withGap(4),
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
  ...railInsetVariants,
} as const;

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-narrow",
  title: "Thread minimap gutter and pane-edge inset variants",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 780, normal: 1040, wide: 1600 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  variants: threadMinimapGalleryVariants,
});
