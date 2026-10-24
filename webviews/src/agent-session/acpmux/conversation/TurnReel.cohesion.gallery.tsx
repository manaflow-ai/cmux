// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { TurnReelProps } from "./TurnReel";
import { BROWSER_RUN, reelPlay } from "./turnReelFixture";

/**
 * Cohesion's turn-reel comparisons keep the stage fixed and vary only the step-change treatment,
 * mark, and strip feedback. Each arm uses the same fixture and play contract as the other lanes.
 */
export default componentEntry<TurnReelProps>({
  id: "agent-pane.turn-reel.cohesion",
  title: "Turn reel — cohesion",
  area: "Agent pane",
  height: 420,
  experimental: true,
  covers: ["agent-session/acpmux/conversation/TurnReel.tsx#TurnReel"],
  anchors: [{ selector: ".cv-reel__stage" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The fixed stage must not move while a strip step changes." },
    layoutShiftMax: { value: 0, reason: "The reel keeps the first frame's aspect and stable strip geometry." },
    longFrameFailMs: { value: 33, reason: "Step changes use compositor-only opacity and transform." },
  },
  load: () => import("./TurnReel").then((module) => module.TurnReel),
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../chips/chips.css"),
      import("./TurnReel.cohesion.gallery.css"),
    ]),
  variants: {
    "cohesion-instant": {
      props: { frames: BROWSER_RUN, initial: 5, look: "cohesion-instant" },
      play: reelPlay,
      checks: {
        settleMaxMs: {
          value: 130,
          reason: "The instant arm has the shared 80 ms strip feedback and no stage transition.",
        },
      },
      note: "Instant step changes keep the stage quiet; selection and hover carry the feedback.",
    },
    "cohesion-crossfade": {
      props: { frames: BROWSER_RUN, initial: 3, mark: "crosshair", look: "cohesion-crossfade" },
      play: reelPlay,
      checks: {
        settleMaxMs: { value: 170, reason: "The crossfade is 120 ms with a 50 ms measurement margin." },
      },
      note: "A short crossfade keeps the stage readable while the crosshair preserves the click location.",
    },
    "cohesion-slide": {
      props: { frames: BROWSER_RUN, initial: 1, look: "cohesion-slide" },
      play: reelPlay,
      checks: {
        settleMaxMs: { value: 230, reason: "The directional slide is 180 ms with a 50 ms measurement margin." },
      },
      note: "A restrained directional slide connects the prior step to the selected thumbnail.",
    },
  },
});
