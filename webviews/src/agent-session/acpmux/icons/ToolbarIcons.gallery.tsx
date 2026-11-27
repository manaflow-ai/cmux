// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { ToolbarIconsGallery, type ToolbarIconsGalleryProps } from "./ToolbarIconsGallery";

export default componentEntry<ToolbarIconsGalleryProps>({
  id: "agent-pane.toolbar-icons",
  title: "Toolbar and tab icons",
  area: "Agent pane",
  pane: true,
  height: 360,
  covers: ["agent-session/acpmux/icons/ToolbarIconsGallery.tsx"],
  load: async () => ToolbarIconsGallery,
  styles: () => import("../../../ui/ui.css"),
  variants: {
    "sliding-bar": {
      props: { toggle: "sliding-bar" },
      note: "Chosen: the divider slides to the left edge and shortens to a bar as the sidebar hides; outlined globe and bare prompt.",
    },
    "filling-rail": {
      props: { toggle: "filling-rail" },
      note: "Comparison: the left column fills while the sidebar shows and empties as it hides. The bar never moves.",
    },
    "arrow-swap": {
      props: { toggle: "arrow-swap", before: true },
      note: "Before: a chevron that swaps direction with no motion, the one-curve globe and the framed prompt.",
    },
  },
});
