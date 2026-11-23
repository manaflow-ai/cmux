// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { EvacuateControl } from "./EvacuateControl";
import { EVACUATES, evacuateAt } from "./fixtures";
import type { EvacuateState } from "./placeModel";

type Props = Parameters<typeof EvacuateControl>[0];

const noop = () => undefined;
const props = (look: Props["look"], state?: EvacuateState): Props => ({
  look,
  ...(state ? { state, now: evacuateAt(state) } : {}),
  onEvacuate: noop,
  onCancel: noop,
});

export default componentEntry<Props>({
  id: "agent-pane.evacuate",
  title: "Evacuate to Cloud: button and progress",
  area: "Agent pane",
  covers: ["agent-session/acpmux/place/EvacuateControl.tsx#EvacuateControl"],
  pane: true,
  load: () => import("./EvacuateControl").then((module) => module.EvacuateControl),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 340,
  variants: {
    idle: {
      note: "The visible button in the chat list's header: every chat on this Mac moves, each to its own Cloud VM. It was only a right-click row before.",
      props: props("panel"),
    },
    "panel-running": {
      note: "Shipped: one row per chat with its step i/8 or its state, the clock and Cancel. Five chats: one in Cloud, two moving at different steps, one waiting, one failed. The only look that says which chat is where.",
      props: props("panel", EVACUATES.running),
    },
    "panel-finished": {
      note: "Done with one failure: the count, the reason on the failed chat, and Retry for just that chat.",
      props: props("panel", EVACUATES.finished),
    },
    "bar-running": {
      note: "Rejected as the default: one summary line and a segmented bar, one segment per chat. It costs the least height but a person cannot tell which chat is which.",
      props: props("bar", EVACUATES.running),
    },
    "bar-finished": {
      note: "Done with one failure: the warm segment is the failed chat; Retry runs it again.",
      props: props("bar", EVACUATES.finished),
    },
    "chip-running": {
      note: "Rejected as the default: a compact pill in the header, 'Moving 3 of 5 to Cloud', with Cancel. It takes no height but shows no chat and no failure reason.",
      props: props("chip", EVACUATES.running),
    },
    "chip-finished": {
      note: "Done with one failure: the pill says so and offers Retry, next to the button.",
      props: props("chip", EVACUATES.finished),
    },
  },
});
