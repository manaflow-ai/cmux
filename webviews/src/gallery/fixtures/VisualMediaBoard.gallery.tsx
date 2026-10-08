// l10n-allow-file: gallery fixtures (portable visual previews), not shipped UI.
import { componentEntry } from "../format";
import type { Play } from "../play";

type Props = Record<string, never>;

const motionControls: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Pause previews" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Play previews" }).getAttribute("aria-pressed") === "true");
  await ctx.click({ role: "button", name: "Play previews" });
  await ctx.waitFor(
    () => ctx.find({ role: "button", name: "Pause previews" }).getAttribute("aria-pressed") === "false",
  );
  await ctx.click({ role: "button", name: "Pulse loop, pause preview" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Pulse loop, resume preview" }));
  await ctx.click({ role: "button", name: "Pulse loop, resume preview" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Pulse loop, pause preview" }));
};

export default componentEntry<Props>({
  id: "gallery.visual-media-board",
  title: "Visual media board",
  area: "Experimental",
  covers: [
    "agent-session/acpmux/conversation/ImageViewer.tsx#ImageViewer",
    "agent-session/acpmux/chips/ReplyMedia.tsx#ReplyMedia",
  ],
  height: 760,
  widths: { narrow: 420, normal: 760, wide: 1080 },
  load: () => import("./VisualMediaBoard").then((module) => module.VisualMediaBoard),
  styles: () => import("./VisualMediaBoard.css"),
  variants: {
    "all-previews": {
      note: "A portable grid for stills, frame sequences, and format targets; click a motion card to pause it.",
      props: {},
    },
    "motion-controls": {
      note: "Replay global pause/play and a card-level pause/resume while the static previews stay visible.",
      props: {},
      play: motionControls,
    },
  },
});
