// l10n-allow-file: gallery fixtures, not shipped UI.
// Three treatments share the real TurnReel and the judge's reelPlay interaction.
import { componentEntry } from "../../../gallery/format";
import type { TurnReelProps } from "./TurnReel";
import { BROWSER_RUN, reelPlay } from "./turnReelFixture";

type EntryProps = TurnReelProps;

export default componentEntry<EntryProps>({
  id: "agent-pane.turn-reel.tt-motion",
  title: "Turn reel · motion entries",
  area: "Agent pane",
  height: 420,
  experimental: true,
  covers: ["agent-session/acpmux/conversation/TurnReel.tsx#TurnReel"],
  load: () => import("./TurnReel").then((module) => module.TurnReel),
  anchors: [{ selector: ".cv-reel__stage" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Changing a reel step must leave the fixed stage in place." },
    layoutShiftMax: { value: 0, reason: "A step change is a composited image treatment with no layout shift." },
    longFrameFailMs: { value: 33, reason: "A finite transform or opacity treatment must not create a long frame." },
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("./TurnReel.tt-motion.gallery.css"),
    ]),
  variants: {
    "tt-motion-crossfade": {
      props: { frames: BROWSER_RUN, look: "tt-motion-crossfade", mark: "ring" },
      play: reelPlay,
      note: "The stage crossfades the selected frame while the strip keeps a quiet accent selection.",
      checks: { settleMaxMs: { value: 230, reason: "The crossfade uses the standard 180 ms motion scale." } },
    },
    "tt-motion-slide": {
      props: { frames: BROWSER_RUN, look: "tt-motion-slide", mark: "crosshair", initial: 3 },
      play: reelPlay,
      note: "The selected frame enters with a short directional 180 ms slide and a restrained crosshair.",
      checks: { settleMaxMs: { value: 230, reason: "The directional stage uses one standard 180 ms transition." } },
    },
    "tt-motion-trace": {
      props: { frames: BROWSER_RUN, look: "tt-motion-trace", mark: "ring", initial: 1 },
      play: reelPlay,
      note: "The frame remains stable while the click marker settles once over the new step.",
      checks: { settleMaxMs: { value: 290, reason: "The marker uses the existing large 240 ms scale once per step." } },
    },
  },
});
