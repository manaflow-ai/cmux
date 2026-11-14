// l10n-allow-file: gallery fixtures (a sample project), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { TourOfferDesign } from "./TourOfferDesigns";

type Props = { design: TourOfferDesign; project?: string };

export default componentEntry<Props>({
  id: "agent-pane.repo-tour-offer-designs",
  title: "Repo tour offer placement (designs)",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/repoTour/TourOfferDesigns.tsx#TourOfferDesigns"],
  styles: () => import("../styles.css"),
  load: () => import("./TourOfferDesigns").then((module) => module.TourOfferDesigns),
  widths: { narrow: 400, normal: 640, wide: 900 },
  height: 440,
  variants: {
    line: {
      note: "Picked, and the one that ships: one quiet line under the question. It never moves the question and reads as part of the hero, not a nag.",
      props: { design: "line" },
    },
    row: {
      note: "A suggestion row above the composer: close to where the eye goes to type, but it competes with the composer's own chips and Tab suggestion.",
      props: { design: "row" },
    },
    card: {
      note: "A card in the hero with a why and a button: the clearest pitch, but it is the loudest thing on an empty chat and reads as onboarding chrome.",
      props: { design: "card" },
    },
  },
});
