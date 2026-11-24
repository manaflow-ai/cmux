// l10n-allow-file: gallery fixtures, not shipped UI.
// The native sidebar's scroll edge fade (Leo, 2026-11-22): "there's simultaneously a fade AND a
// hard break ideally lessen the hard break." The linear 22 pt ramp has a kink where it meets full
// ink, which reads as a line, and the band is too short.
// Pick "eased-tall": a smoothstep ramp at 9 stops, 24 px at the top and a taller 44 px at the bottom.
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import type { SidebarEdgeFadeDesignsProps } from "./SidebarEdgeFadeDesigns";

const load = () => import("./SidebarEdgeFadeDesigns").then((module) => module.SidebarEdgeFadeDesigns);
const covers = ["sidebar/SidebarEdgeFadeDesigns.tsx#SidebarEdgeFadeDesigns"];
/** Scrolled to the middle of the 30 rows, so both edges fade. */
const midScroll: Play = (ctx) => ctx.scroll({ selector: ".sef-scroll" }, 180);

export default componentEntry<SidebarEdgeFadeDesignsProps>({
  id: "sidebar.edge-fade",
  title: "Sidebar scroll edge fade: eased, taller bottom (Leo 2026-11-22)",
  area: "Sidebar",
  covers,
  height: 560,
  keywords: ["fade", "mask", "scroll", "edge", "smoothstep", "footer"],
  load,
  variants: {
    "eased-tall": {
      note: "Pick. Smoothstep ramp at 9 stops, 24 px top and 44 px bottom; no kink, the bottom row dissolves gradually",
      props: { variant: "eased-tall" },
      play: midScroll,
    },
    linear: {
      note: "Today's baseline: linear 4-stop ramp, 22 px top and bottom; the kink reads as a hard line",
      props: { variant: "linear" },
      play: midScroll,
    },
    eased: {
      note: "Smoothstep at 9 stops, still 22 px: no kink, but the band is short",
      props: { variant: "eased" },
      play: midScroll,
    },
    "eased-tall-under-footer": {
      note: "Smoothstep 24/56 px with the list running under the footer, so rows fade behind the avatar",
      props: { variant: "eased-tall-under-footer" },
      play: midScroll,
    },
    "eased-tall-rest": {
      note: "Pick at rest (not scrolled): no top fade, only the 44 px bottom fade",
      props: { variant: "eased-tall" },
    },
  },
});
