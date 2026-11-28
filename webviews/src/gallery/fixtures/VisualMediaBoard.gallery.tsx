// l10n-allow-file: gallery fixtures (portable visual previews), not shipped UI.
import { componentEntry } from "../format";

type Props = Record<string, never>;

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
  },
});
