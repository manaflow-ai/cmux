// l10n-allow-file: synthetic gallery labels, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { IndicatorTravel } from "../../../ui/motion/SlidingIndicator";

export default componentEntry<{ travel?: IndicatorTravel }>({
  id: "new-tab.dot-focus",
  title: "New Tab dot focus",
  area: "New Tab",
  height: 200,
  widths: { narrow: 340, normal: 540, wide: 760 },
  covers: ["agent-session/acpmux/newtab/StyleSwitch.tsx#DotSwitch"],
  load: async () => (await import("./DotSwitch.fixture")).default,
  styles: () => Promise.all([import("./screen.css"), import("./DotSwitch.gallery.css")]),
  // How the accent dot travels to a pick (ui/motion useSlidingIndicator). Shipped: `initial`, the
  // scale's ease-out over 180 ms, as design/new-tab.md specifies. Click a dot to compare.
  variants: {
    initial: { props: {}, note: "Shipped: the accent dot eases to a pick over 180 ms" },
    spring: { props: { travel: "spring" }, note: "The accent dot travels on the shared spring (240 ms)" },
    still: { props: { travel: "none" }, note: "The accent dot jumps to a pick, no travel" },
  },
});
