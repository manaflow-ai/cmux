// l10n-allow-file: gallery fixtures (sample paths and file text), not shipped UI.
// The edited-files card with its turn's before and after picture of the chat's page
// (TurnShotsPair.tsx, turnShots.ts): the split the card ships with (the person drags it or moves it
// with the arrow keys), and the shared pair's other modes as candidates (side by side, a Before /
// After toggle), plus a pair that arrives while the card shows and grows in through the motion gate.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { activity, tool } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { CompareMode } from "../../../ui/MediaCompare";
import { EditedFilesCard } from "../conversation/EditedFilesCard";
import { PAGE_AFTER, PAGE_BEFORE } from "./turnShotFixtures";
import { TurnShotsContext, type TurnShotPair, type TurnShotsReader } from "./turnShots";

type Props = { mode?: CompareMode; arriveMs?: number };

const EDIT = {
  path: "/Users/you/acme/src/pages/Pricing.tsx",
  oldText: "export const theme = 'light';\n",
  newText: "export const theme = 'dark';\nexport const highlight = 'team';\n",
};
const ROW = {
  ...activity([tool("Edit src/pages/Pricing.tsx", "edit", "completed", { diffs: [EDIT] })], 2),
  ended: true,
};
const PAIR: TurnShotPair = { before: PAGE_BEFORE, after: PAGE_AFTER };

function TurnShotsGallery({ mode, arriveMs }: Props) {
  const reader = useMemo<TurnShotsReader>(() => {
    let settled: { pair?: TurnShotPair } | undefined = arriveMs ? undefined : { pair: PAIR };
    return {
      mode,
      peek: () => settled,
      read: () =>
        new Promise((resolve) =>
          setTimeout(() => {
            settled = { pair: PAIR };
            resolve(PAIR);
          }, arriveMs ?? 0),
        ),
    };
  }, [mode, arriveMs]);
  return (
    <div className="acpmux-shell" data-gallery-capture="" style={{ width: 520, padding: 16 }}>
      <TurnShotsContext.Provider value={reader}>
        <EditedFilesCard row={ROW} sessionId="gallery" />
      </TurnShotsContext.Provider>
    </div>
  );
}

const scrub: Play = async (ctx) => {
  await ctx.focus({ selector: ".ui-compare-range" });
  for (let step = 0; step < 25; step += 1) await ctx.press("ArrowLeft");
  await ctx.waitFor(() => ctx.document.querySelector<HTMLInputElement>(".ui-compare-range")?.value === "25");
};
const showBefore: Play = async (ctx) => {
  await ctx.click({ selector: ".ui-compare-switch button" });
  await ctx.waitFor(() => ctx.document.querySelector('.ui-compare[data-showing="before"]'));
};
const arrive: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-turn-shots[data-arrived] .ui-compare"));
};

export default componentEntry<Props>({
  id: "agent-pane.turn-shots",
  title: "Turn before/after pictures",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/turnChanges/TurnShotsPair.tsx#TurnShots", "ui/MediaCompare.tsx#MediaCompare"],
  load: async () => TurnShotsGallery,
  styles: () => Promise.all([import("../styles.css"), import("./turnChanges.css")]),
  variants: {
    slider: {
      props: {},
      note: "Picked: the split, before on the left. One frame, so dragging moves nothing around it.",
    },
    "slider-scrubbed": { props: {}, play: scrub, note: "Arrow keys move the split (here to 25%)." },
    side: { props: { mode: "side" }, note: "Candidate: both halves at once; each picture is half as wide." },
    toggle: { props: { mode: "toggle" }, note: "Candidate: one picture, a Before / After switch." },
    "toggle-before": { props: { mode: "toggle" }, play: showBefore },
    arrives: {
      props: { arriveMs: 300 },
      play: arrive,
      note: "The pair is read once the turn ends and grows in; motion off or reduced shows it at once.",
    },
  },
});
