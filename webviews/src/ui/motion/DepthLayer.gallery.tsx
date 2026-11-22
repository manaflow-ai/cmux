// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { DepthDemo, type DepthDemoProps } from "./MotionDemos";

// Picked: parallax. It moves only while the pointer does, so at rest it costs nothing; drift gives the
// reference's live background (private reference zenless-zone-zero/live/motion-sunbringer-menu-animation-sheet) but runs the
// compositor for 24 s after each show.
export default componentEntry<DepthDemoProps>({
  id: "ui.motion-depth-layer",
  title: "Depth layer",
  area: "UI primitives",
  height: 330,
  covers: ["ui/motion/DepthLayer.tsx", "ui/motion/MotionDemos.tsx#DepthDemo"],
  load: async () => DepthDemo,
  styles: () => Promise.all([import("./motion.css"), import("./motion.gallery.css")]),
  variants: {
    parallax: { note: "Picked: the washes lean toward the pointer.", props: { look: "parallax" } },
    drift: { note: "One slow 24 s drift after it shows, then rest.", props: { look: "drift" } },
    "drift-parallax": { note: "Both.", props: { look: "drift-parallax" } },
    still: { note: "The washes, nothing moves.", props: { look: "still" } },
  },
});
