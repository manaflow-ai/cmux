// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { TurnReelProps } from "./TurnReel";
import { BROWSER_RUN, FAILED_RUN, LONG_RUN, MIXED_RUN, RUN_RECORDING, reelPlay } from "./turnReelFixture";

export default componentEntry<TurnReelProps>({
  id: "agent-pane.turn-reel",
  title: "Turn reel",
  area: "Agent pane",
  height: 420,
  experimental: true,
  covers: ["agent-session/acpmux/conversation/TurnReel.tsx#TurnReel"],
  load: () => import("./TurnReel").then((module) => module.TurnReel),
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  variants: {
    ring: {
      props: { frames: BROWSER_RUN },
      play: reelPlay,
      note: "A six-step sign-in run; the stage shows the last step, a ring marks each click",
    },
    crosshair: { props: { frames: BROWSER_RUN, mark: "crosshair", initial: 3 }, play: reelPlay },
    ripple: {
      props: { frames: BROWSER_RUN, mark: "ripple", initial: 1 },
      play: reelPlay,
      note: "The ring grows in once per step shown; still under Reduce Motion",
    },
    "failed-step": {
      props: { frames: FAILED_RUN },
      note: "The failed step is outlined in the failure color and its caption says so",
    },
    "long-run": { props: { frames: LONG_RUN }, note: "24 steps: the strip scrolls sideways and fades at its edges" },
    "mixed-shapes": {
      props: { frames: MIXED_RUN },
      note: "A 16:9 frame letterboxed in the first frame's 16:10 stage; the mark still lands on the click",
    },
    recording: {
      props: { frames: BROWSER_RUN, video: RUN_RECORDING },
      note: "Play loads the recording only when pressed",
    },
    "single-frame": { props: { frames: BROWSER_RUN.slice(3, 4) } },
  },
});
