// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the transcript's scrollbar thumb takes the pointer coming near its bar (scrollers.ts
/// `followShownScrollerFade`, `ScrollerNearMotion`). Leo, 2026-11-20, in his NIGHTLY: "the thumb needs
/// to look better when i do stuff". Before, reaching for it drew it wide at 55% in one frame from
/// nothing at rest, and leaving took it away in one frame (his 2026-10-29: "the scroll thumb should
/// fade instead of disappearing instantly").
export const thumbMotion = defineExperiment({
  id: "thumb-motion",
  title: "Transcript thumb near the pointer",
  description:
    "The scrollbar thumb as the pointer reaches its bar and leaves: faded and widened, faded thin, or at once.",
  arms: {
    fade: {
      label: "Fade wide",
      description: "Fades in to the near ink and widens over the pane's fade, and back out as the pointer leaves.",
    },
    thin: {
      label: "Fade thin",
      description: "The same fade to the near ink, staying as thin as it is while scrolling.",
    },
    instant: {
      label: "At once",
      description: "The near look in one frame, and gone in one frame (before).",
    },
  },
  defaultArm: "fade",
});
