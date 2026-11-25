// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { IconSystemGallery, type IconSystemGalleryProps } from "./IconSystemGallery";

export default componentEntry<IconSystemGalleryProps>({
  id: "agent-pane.icon-system",
  title: "One icon system",
  area: "Agent pane",
  pane: true,
  height: 640,
  covers: [
    "agent-session/acpmux/icons/Icon.tsx",
    "agent-session/acpmux/conversation/icons.tsx",
    "agent-session/acpmux/icons/IconSystemGallery.tsx",
  ],
  load: async () => IconSystemGallery,
  styles: () => Promise.all([import("../../../ui/ui.css"), import("./iconSystemGallery.css")]),
  variants: {
    "mixed-before": {
      props: { look: "mixed-before" },
      note: "Before: transcript Copy at 1.25, tool glyphs at 1.1, and the cmux pack on its 24-unit grid.",
    },
    "unified-after": {
      props: { look: "unified-after" },
      note: "Chosen: transcript and cmux pack share their drawings and a 1.25px stroke at 16px.",
    },
    "heavier-comparison": {
      props: { look: "heavier-comparison" },
      note: "Comparison: the same pack at 1.5px per 16px. More ink than the quiet transcript needs.",
    },
  },
});
