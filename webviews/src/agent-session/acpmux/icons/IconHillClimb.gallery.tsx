// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { IconHillClimbGallery, type IconHillClimbGalleryProps } from "./IconHillClimbGallery";

export default componentEntry<IconHillClimbGalleryProps>({
  id: "agent-pane.icon-hillclimb",
  title: "Icon hill-climb backlog",
  area: "Agent pane",
  pane: true,
  height: 1500,
  covers: ["agent-session/acpmux/icons/IconHillClimbGallery.tsx"],
  load: async () => IconHillClimbGallery,
  styles: () => Promise.all([import("../../../ui/ui.css"), import("./iconHillClimbGallery.css")]),
  variants: {
    light: {
      props: { scheme: "light" },
      note: "Open: each row's current pack drawing (dashed) beside its candidates, light. Pick one per row.",
    },
    dark: {
      props: { scheme: "dark" },
      note: "Open: the same backlog in dark.",
    },
  },
});
