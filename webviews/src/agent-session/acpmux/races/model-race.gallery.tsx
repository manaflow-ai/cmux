// l10n-allow-file: gallery metadata and synthetic race fixtures.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { RaceCompareView } from "./RaceCompareView";
import { fixtureRaceClient, raceFixture } from "./fixtures";
import type { RaceRecord } from "./model";

const props = (race: RaceRecord): ComponentProps<typeof RaceCompareView> => ({
  parent: race.parent,
  raceId: race.id,
  initialRace: race,
  client: fixtureRaceClient(race),
});
export default componentEntry<ComponentProps<typeof RaceCompareView>>({
  id: "agent-pane.model-race",
  title: "Model race",
  area: "Agent pane",
  pane: true,
  height: 600,
  widths: { narrow: 420, normal: 900, wide: 1200 },
  covers: ["agent-session/acpmux/races/RaceCompareView.tsx#RaceCompareView"],
  styles: () => import("./styles.css"),
  load: async () => (await import("./RaceCompareView")).RaceCompareView,
  variants: {
    completed: {
      props: props(raceFixture),
      note: "Actual reply text and the reviewer-selected winner; no synthetic proof cards.",
    },
    reviewing: {
      props: props({
        ...raceFixture,
        state: "reviewing",
        winnerId: undefined,
        reason: undefined,
        candidates: raceFixture.candidates.map((candidate) => ({
          ...candidate,
          state: "completed",
        })),
      }),
      note: "Both replies remain visible while the reviewer decides.",
    },
    running: {
      props: props({
        ...raceFixture,
        state: "running",
        winnerId: undefined,
        reason: undefined,
        candidates: raceFixture.candidates.map((candidate) => ({
          ...candidate,
          state: "running",
          reply: undefined,
        })),
      }),
      note: "Stable candidate columns while workers run.",
    },
  },
});
