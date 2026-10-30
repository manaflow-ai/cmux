// l10n-allow-file: gallery fixtures (portable visual previews), not shipped UI.
import { componentEntry } from "../format";
import type { Play } from "../play";

type Props = Record<string, never>;

const playback: Play = async (ctx) => {
  const card = (prefix: string) =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>(".cmux-gallery-media-stage")].find((button) =>
      button.getAttribute("aria-label")?.startsWith(prefix),
    );

  await ctx.click({ role: "button", name: "Pause previews" });
  await ctx.waitFor(() => card("Pulse loop, paused by the global control")?.getAttribute("aria-pressed") === "true");

  await ctx.click({ role: "button", name: "Play previews" });
  await ctx.waitFor(() => {
    const pulse = card("Pulse loop, pause preview");
    return pulse?.getAttribute("aria-pressed") === "false";
  });

  await ctx.click({ role: "button", name: "Pulse loop, pause preview" });
  await ctx.waitFor(() => card("Pulse loop, resume preview")?.getAttribute("aria-pressed") === "true");
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
  checks: {
    layoutShiftMax: {
      value: 0,
      reason: "Playback controls change card state without reflowing the media board.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Global and card playback controls should settle within one responsive interaction frame.",
    },
    settleMaxMs: {
      value: 300,
      reason: "Playback state changes should settle promptly while scanning previews.",
    },
  },
  load: () => import("./VisualMediaBoard").then((module) => module.VisualMediaBoard),
  styles: () => import("./VisualMediaBoard.css"),
  variants: {
    "all-previews": {
      note: "A portable grid for stills, frame sequences, and format targets; click a motion card to pause it.",
      props: {},
      play: playback,
    },
  },
});
