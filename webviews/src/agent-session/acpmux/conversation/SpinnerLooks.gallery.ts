// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent working-state mark's looks, in light and dark at 12, 14 and 16 px: (b) a faint ring
// with a short bright sweep (shipped, native and web), (c) a conic sweep with a fading tail, and
// the two rejected marks for reference: the 3/4 arc (Leo 2026-10-31: "who even decided to put that
// 3/4 circle") and the macOS spokes (Leo 2026-11-01: "why the f*** did you make the spinner into
// this????"). (b) won: at 12-14 px the conic tail fades into a smudge, while the sweep's head
// stays crisp and matches the native CAShapeLayer mark.
import { componentEntry } from "../../../gallery/format";
import type { SpinnerLooksBoardProps } from "./SpinnerLooksBoard";

export default componentEntry<SpinnerLooksBoardProps>({
  id: "agent-pane.working-spinner",
  title: "Working spinner: looks",
  area: "Agent pane",
  height: 240,
  covers: [
    "agent-session/acpmux/conversation/icons.tsx#Spinner",
    "agent-session/acpmux/conversation/SpinnerLooksBoard.tsx",
  ],
  keywords: ["spinner", "working", "ring", "sweep", "arc", "spokes", "conic"],
  styles: () => import("./spinner.css"),
  load: () => import("./SpinnerLooksBoard").then((module) => module.SpinnerLooksBoard),
  variants: {
    compare: {
      note: "All four side by side; (b) ring + sweep ships.",
      props: { looks: ["ring-sweep", "conic", "arc", "spokes"] },
    },
    "ring-sweep": {
      note: "Shipped: a faint full ring (22%) with an 80° bright sweep, round caps, turning on the shared clock.",
      props: { looks: ["ring-sweep"] },
    },
    conic: {
      note: "Runner-up: a thin ring whose conic gradient fades behind a turning head.",
      props: { looks: ["conic"] },
    },
    rejected: {
      note: "For reference only: the 3/4 arc and the macOS spokes, both rejected by Leo.",
      props: { looks: ["arc", "spokes"] },
    },
  },
});
