import { componentEntry } from "../../gallery/format";
import type { TourOfferActions } from "./repoTour/TourOffer";

type Props = { tour?: TourOfferActions };

const tour: TourOfferActions = { onTake: () => undefined, onDismiss: () => undefined };

export default componentEntry<Props>({
  id: "agent-pane.empty-state",
  title: "Plain new chat",
  area: "Agent pane",
  covers: ["agent-session/acpmux/EmptyState.tsx#EmptyState", "agent-session/acpmux/repoTour/TourOffer.tsx#TourOffer"],
  load: () => import("./EmptyState").then((module) => module.EmptyState),
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 420,
  checks: {
    layoutShiftMax: { value: 0, reason: "The plain new chat draws nothing that moves." },
    longFrameFailMs: { value: 33, reason: "An empty chat draws on its first frame." },
  },
  variants: {
    plain: {
      note: "A new chat with no turns, on every path (new, connecting, reconnecting, a host error): no question, no project picker, no lists. The builder screen is an opt-in look (examples/looks/codex/send-parity).",
      props: {},
    },
    "tour-offer": {
      note: "A folder no chat has used: Take a tour of this repo, centered; a dim × (Not now) sits beside it.",
      props: { tour },
    },
    "tour-offer-hover": {
      note: "Hovering the offer fills it; the × closes it for this folder.",
      props: { tour },
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-tour-offer-take" });
      },
    },
  },
});
