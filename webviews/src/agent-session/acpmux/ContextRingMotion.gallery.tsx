// l10n-allow-file: gallery fixtures and captions, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ContextRing } from "./ComposerPickers";
import { contextRingMotion } from "./contextRingMotion.experiment";

type Props = {
  /// The share used before and after (percent): a compaction's drop or a turn's rise.
  from: number;
  to: number;
  /// The ring's look (context-ring-look); `percent` draws the percent beside it.
  look?: "track" | "percent";
};

const SIZE = 400_000;

/// One ring in one chat, and a button that brings its next reading.
function GalleryRingMotion({ from, to, look }: Props) {
  const [next, setNext] = useState(false);
  if (look) globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "context-ring-look": look };
  return (
    <div className="context-ring-motion-gallery" data-reading={next ? "next" : "first"}>
      <span className="context-ring-motion-gallery__ring">
        <ContextRing chat="gallery-chat" used={((next ? to : from) / 100) * SIZE} size={SIZE} />
      </span>
      <button type="button" className="context-ring-motion-gallery__next" onClick={() => setNext((was) => !was)}>
        {next ? `Back to ${from}%` : `${from}% → ${to}%`}
      </button>
    </div>
  );
}

const nextReading: Play = async (ctx) => {
  await ctx.click({ selector: ".context-ring-motion-gallery__next" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-reading="next"]'));
};

/// Back to the first reading (the button toggles), waiting for the first reading's state.
const firstReading: Play = async (ctx) => {
  await ctx.click({ selector: ".context-ring-motion-gallery__next" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-reading="first"]'));
};

/// The experiment starts at the first reading whatever the variant's play left: the variants with a
/// play end on the next reading, and the script's "Next reading" would then toggle back and wait.
const startAtFirst: Play = async (ctx) => {
  if (!ctx.document.querySelector('[data-reading="next"]')) return;
  await firstReading(ctx);
};

/// The next reading, held 300 ms into its 600 ms ease (every running motion paused there).
const holdMidway: Play = async (ctx) => {
  await nextReading(ctx);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 300;
  }
};

/// The next reading once it has settled.
const settle: Play = async (ctx) => {
  await nextReading(ctx);
  for (const animation of ctx.document.getAnimations()) animation.finish();
};

export default componentEntry<Props>({
  id: "agent-pane.context-ring-motion",
  title: "Context ring motion",
  area: "Agent pane",
  pane: true,
  height: 140,
  widths: { narrow: 360, normal: 520 },
  anchors: [{ selector: ".acpmux-context" }],
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ContextRing"],
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./composerFooterShared.css"),
      import("./ContextRingMotion.gallery.css"),
    ]),
  checks: {
    anchorMovePx: { value: 0, reason: "A new reading moves the arc, never the ring's box." },
    layoutShiftMax: { value: 0, reason: "The ring and its percent hold their size while the arc eases." },
  },
  load: async () => GalleryRingMotion,
  // Leo (2026-11-07): "after a compaction ... it goes back down. I feel like that should, like, play a
  // cute little, like, eased animation that goes down." Compare the arms held mid-way (variants
  // *-mid); `ease` shipped: the CSS transition on one registered number, the percent counting with it.
  experiment: {
    definition: contextRingMotion,
    setup: startAtFirst,
    script: [
      { name: "Next reading", run: nextReading },
      { name: "Back", run: firstReading },
    ],
  },
  variants: {
    "compaction-mid": {
      note: "A compaction, 85% to 12%, held 300 ms into the 600 ms ease-out: the arc is most of the way down and still moving.",
      props: { from: 85, to: 12 },
      play: holdMidway,
    },
    "compaction-end": {
      note: "The same drop settled at 12%.",
      props: { from: 85, to: 12 },
      play: settle,
    },
    "rise-mid": {
      note: "A turn, 40% to 55%, held mid-way: a small rise eases the same way.",
      props: { from: 40, to: 55 },
      play: holdMidway,
    },
    "percent-compaction-mid": {
      note: "The percent look mid-drop: the percent counts down with the arc (it reads the same eased number), or jumps in `ease-number-jumps`.",
      props: { from: 85, to: 12, look: "percent" },
      play: holdMidway,
    },
    "percent-rise-mid": {
      note: "The percent look mid-rise, 40% to 55%.",
      props: { from: 40, to: 55, look: "percent" },
      play: holdMidway,
    },
    rest: {
      note: "At rest, as a chat opens at 85%: drawn at once, nothing moving.",
      props: { from: 85, to: 12 },
    },
  },
});
