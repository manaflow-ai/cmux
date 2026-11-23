// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { AutoReserveControl } from "./AutoReserveControl";
import { RESERVES } from "./fixtures";

type Props = Parameters<typeof AutoReserveControl>[0];

const onChange = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.auto-reserve",
  title: "Auto on reserve: Keep for me (RFD 0072, shadow)",
  area: "Agent pane",
  covers: ["agent-session/acpmux/place/AutoReserveControl.tsx#AutoReserveControl"],
  pane: true,
  load: () => import("./AutoReserveControl").then((module) => module.AutoReserveControl),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 200,
  variants: {
    "stops-off": {
      note: "Shipped under Auto in the place menu: the switch, off by default, and the four stops dimmed.",
      props: { look: "stops", reserve: RESERVES.off, onChange },
    },
    "stops-on": {
      note: "On at the default 50%: four stops in one segmented row, one click each, and the trial line saying nothing moves yet.",
      props: { look: "stops", reserve: RESERVES.on, onChange },
    },
    "slider-on": {
      note: "A slider with its four stops marked: reads as a continuous amount, but a drag has only four places to land.",
      props: { look: "slider", reserve: RESERVES.on, onChange },
    },
    "card-would-move": {
      note: "The rows look's panel: the slider plus the last chat Auto would have moved and why, from the shadow line.",
      props: { look: "card", reserve: RESERVES.wouldMove, onChange },
    },
    "card-none-yet": {
      note: "The panel before any would-be move.",
      props: { look: "card", reserve: RESERVES.on, onChange },
    },
  },
});
