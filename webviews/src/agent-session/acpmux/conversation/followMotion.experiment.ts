// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the followed transcript moves when the reader sends and while a reply streams (followChase.ts).
/// Leo, 2026-11-07: "When it comes to sending messages, I feel like the jump, the jolt is a bit too
/// jarring ... what is satisfying at 120 hertz? That's what we want to aim at." To try another arm,
/// set `cmux.experiments` to `{"follow-motion":"chunk"}` in the pane's web inspector and reload.
export const followMotion = defineExperiment({
  id: "follow-motion",
  title: "Send and stream follow motion",
  description:
    "Sending from the latest message and a fast reply streaming in. Watch whether the sent prompt, the rows above it and each new line move as one steady motion, with no jump in a frame and no surge per chunk.",
  arms: {
    spring: {
      label: "Spring chase",
      description:
        "Every move of the rows in view (a line, the prompt and live line arriving, the composer clearing) is drawn back and chased home on one critically damped spring (the 180 ms standard step), at most 450 px/s near home and faster as it nears two lines behind, and a new move keeps the speed it has. It never trails by more than two lines: what lands past that moves at once. New text lies at most a line under the composer; past that it moves at once.",
    },
    blocks: {
      label: "Spring, passes under the composer",
      description:
        "As the spring chase, and new content (a line, a code card, a table) may pass under the glass composer while it settles, as a sent prompt does, instead of moving at once past a line under it. It still never trails by more than two lines.",
    },
    eased: {
      label: "Eased glide (before)",
      description:
        "The view before: a rise with the same rows eases over 180 ms, restarted at each line and capped at the live line's room; rows that arrive and the composer's change move at once.",
    },
    chunk: {
      label: "Eased per chunk",
      description: "Every move of the rows in view restarts a fixed 180 ms ease-out from where they are drawn.",
    },
    linear: {
      label: "Steady chase",
      description:
        "Every move of the rows in view is chased home at a constant 450 px/s (faster as it nears two lines behind), then stops.",
    },
    instant: { label: "At once", description: "Every move lands in the frame it happens, as with motion off." },
  },
  defaultArm: "blocks",
});

export type FollowMotionArm = keyof typeof followMotion.arms;
