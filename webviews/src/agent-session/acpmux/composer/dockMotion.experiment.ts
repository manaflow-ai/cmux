// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the transcript does while the composer grows a line as the person types (VirtualTranscript.tsx
/// `cardHold`). Leo, 2026-11-11, on his NIGHTLY: "ok the fact that [it] is animated up... do we even
/// want stuff to push up vs just simple... covering stuff? im not sure. if we can get it fast, MAYBE /
/// otherwise idk". Both arms are measured in test/agent-pane-composer-dock-motion.test.ts. To try one,
/// set `cmux.experiments` to `{"composer-dock-motion":"push"}` in the pane's web inspector and reload.
export const composerDockMotion = defineExperiment({
  id: "composer-dock-motion",
  title: "Composer growth over the transcript",
  description:
    "Type five lines with Shift-Return at the latest row, then send. Watch the transcript above the composer: it should hold still while the composer grows, and move once on the send.",
  arms: {
    overlay: {
      label: "Overlay",
      description:
        "The transcript holds still while the composer grows over its foot as glass. The room under the last row takes the growth when the rows move anyway (a reply's next line, the send) or when the reader scrolls past the end, so nothing stays out of reach. A send is one move: the composer clears and the bubble rises in, never a drop and a rise.",
    },
    push: {
      label: "Push up (before)",
      description:
        "The transcript rises with the composer's top, on the field growth's own curve (composer/fieldGrowth.ts), and comes back down when the send clears it.",
    },
  },
  defaultArm: "overlay",
});

export type ComposerDockMotionArm = keyof typeof composerDockMotion.arms;
