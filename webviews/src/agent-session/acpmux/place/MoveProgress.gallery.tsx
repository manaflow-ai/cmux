// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { MoveProgress } from "./MoveProgress";
import { MOVES, at } from "./fixtures";
import type { MoveView } from "./placeModel";

type Props = Parameters<typeof MoveProgress>[0];

const noop = () => undefined;
const props = (look: Props["look"], move: MoveView): Props => ({
  look,
  move,
  now: at(move),
  linger: Number.POSITIVE_INFINITY,
  onCancel: noop,
  onRetry: noop,
});

export default componentEntry<Props>({
  id: "agent-pane.move-progress",
  title: "Move progress: to and from Cloud",
  area: "Agent pane",
  covers: ["agent-session/acpmux/place/MoveProgress.tsx#MoveProgress"],
  pane: true,
  load: () => import("./MoveProgress").then((module) => module.MoveProgress),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 260,
  variants: {
    "card-moving": {
      note: "Shipped: a card over the composer. The title, the clock against the 10 s bound, a bar of eight steps, the step by name, and what moves with it. Syncing with uncommitted changes and a running turn that continues on Cloud.",
      props: props("card", MOVES.moving),
    },
    "card-interrupts": {
      note: "A running turn that will be interrupted is said in the list and in the warm colour, in the first step, before anything freezes.",
      props: props("card", MOVES.interrupts),
    },
    "card-over-budget": {
      note: "Past 10 s: it says it is taking longer and which step it waits on.",
      props: props("card", MOVES.overBudget),
    },
    "card-finishing": {
      note: "Cancel was pressed too late: no Cancel, Finishing…",
      props: props("card", MOVES.finishing),
    },
    "card-failed": {
      note: "Failure: the reason, where the chat still runs, and Retry.",
      props: props("card", MOVES.failed),
    },
    "card-live": {
      note: "Done: one brief line that goes away after 2.5 s (held here).",
      props: props("card", MOVES.live),
    },
    "card-auto": {
      note: "Started by Auto: the card says why.",
      props: props("card", MOVES.auto),
    },
    "line-moving": {
      note: "Rejected as the default: one row with the step, its count, the clock and Cancel. It costs the least height but the carries are not listed, which is what a person needs before a move that touches their folder.",
      props: props("line", MOVES.moving),
    },
    "line-interrupts": {
      note: "The interrupted turn is a line under the row.",
      props: props("line", MOVES.interrupts),
    },
    "line-over-budget": {
      note: "Over the bound: the clock turns warm and the row below says what it waits on.",
      props: props("line", MOVES.overBudget),
    },
    "line-failed": {
      note: "Failure on one row plus the reason and Retry.",
      props: props("line", MOVES.failed),
    },
    "steps-moving": {
      note: "Rejected as the default: all eight steps listed with the done ones filled. It shows the most and costs 200 px of height above the composer, which pushes the transcript up for a ten second event.",
      props: props("steps", MOVES.moving),
    },
    "steps-failed": {
      note: "Failure: the stopped step is warm, the reason and Retry follow.",
      props: props("steps", MOVES.failed),
    },
    "steps-live": {
      note: "Every step done.",
      props: props("steps", MOVES.live),
    },
  },
});
