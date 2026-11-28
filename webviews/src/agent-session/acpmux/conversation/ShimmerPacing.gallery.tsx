// l10n-allow-file: gallery fixtures for the Thinking shimmer's pacing, not shipped UI.
// Shimmer pacing (Leo, 2026-11-08, asked whether other agent apps' shimmers are better paced than
// ours). The real live line's layers (ShimmerText.tsx: `cv-shimmer__base`, the masked
// `cv-shimmer__band` and its counter-moving `cv-shimmer__lit`, on the real cadence, shimmerCadence.ts)
// on three lines, under the shipped pace and three candidates. A candidate is a cadence given through
// `ShimmerCadenceContext` (when sweeps start, how long each runs) plus a scoped override in
// ShimmerPacing.gallery.css (band width, lit and resting tones) under `data-pace`. Nothing here changes
// the shipped default: the app never provides another cadence.
import { componentEntry } from "../../../gallery/format";
import { ShimmerCadenceContext, ShimmerText } from "./ShimmerText";
import { DEFAULT_SHIMMER_CADENCE, type ShimmerCadence } from "./shimmerCadence";

type Pace = "current" | "word-band" | "mid-band" | "letter-band";

const CADENCES: Record<Pace, ShimmerCadence> = {
  current: DEFAULT_SHIMMER_CADENCE,
  "word-band": { firstMs: 600, sweepMs: 1400, everyMs: 5000 },
  "mid-band": { firstMs: 600, sweepMs: 1200, everyMs: 4500 },
  "letter-band": { firstMs: 600, sweepMs: 1600, everyMs: 5000 },
};

const LINES = ["Thinking", "Running agent 47s", "Considering the next step"];

function ShimmerPacing({ pace }: { pace: Pace }) {
  return (
    <div className="acpmux-shell cv-shimmer-pacing" data-pace={pace}>
      <ShimmerCadenceContext value={CADENCES[pace]}>
        <div className="cv-shimmer-pacing__lines">
          {LINES.map((line) => (
            // The live line's own nesting (Thinking.tsx): the row holds the line, the line the layers.
            <span key={line} className="cv-shimmer__row">
              <span className="cv-thinking is-shimmer">
                <ShimmerText text={line} />
              </span>
            </span>
          ))}
        </div>
      </ShimmerCadenceContext>
    </div>
  );
}

export default componentEntry<{ pace: Pace }>({
  id: "agent-pane.shimmer-pacing",
  title: "Thinking shimmer: pacing",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 560 },
  covers: [
    "agent-session/acpmux/conversation/ShimmerText.tsx#ShimmerText",
    "agent-session/acpmux/conversation/ShimmerText.tsx#ShimmerCadenceContext",
  ],
  keywords: ["shimmer", "glimmer", "thinking", "pacing", "cadence", "band"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ShimmerPacing.gallery.css")]),
  load: async () => ShimmerPacing,
  variants: {
    current: {
      note: "Shipped, unchanged: a 1 s sweep every 4 s (3 s rest); the stripe is half the line wide; dim words lit to the text color.",
      props: { pace: "current" },
    },
    "word-band": {
      note: "About one word lit (a 5.5em stripe), a slower 1.4 s sweep every 5 s (3.6 s rest).",
      props: { pace: "word-band" },
    },
    "mid-band": {
      note: "A 4em stripe, a 1.2 s sweep every 4.5 s (3.3 s rest).",
      props: { pace: "mid-band" },
    },
    "letter-band": {
      note: "A few letters lit (a 3em stripe) over dimmer resting words, the slowest sweep, 1.6 s every 5 s (3.4 s rest).",
      props: { pace: "letter-band" },
    },
  },
});
