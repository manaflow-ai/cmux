// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the tucked composer hat (TrayPullTab.tsx) takes a running count and gives it back (Leo,
/// 2026-11-07: "if there's no running work, it should just be centered, right? But when there is a
/// number, it can, like, you know, grow into that."). Every arm is just the chevron, centred on the
/// composer, while nothing runs; they differ in how chevron and count arrive and leave. Compare them in
/// the gallery's `agent-pane.composer-hat`.
export const composerHatLook = defineExperiment({
  id: "composer-hat-grow",
  title: "Composer hat count",
  description:
    "The tucked hat's count: a pill that grows with the count sliding out from under the chevron, one that grows with the count fading in place, a crossfade between two fixed widths, or a badge on a pill that never changes.",
  arms: {
    grow: {
      label: "Grow, count slides out",
      description:
        "One width on --agent-motion-move: the pill widens about its centre, the chevron moves aside with it, and the count slides out from under the chevron as it fades in.",
    },
    fade: {
      label: "Grow, count fades in place",
      description:
        "The same widening pill, but the count sits at its final place and is uncovered by the pill's edge as it fades in.",
    },
    crossfade: {
      label: "Crossfade two widths",
      description:
        "Two fixed pills, idle and counted, crossfade; the chevron and the width take their end state at once.",
    },
    badge: {
      label: "Badge",
      description:
        "The pill keeps its idle width and the chevron never moves; the count is a small badge on the pill's corner that fades and rises in.",
    },
  },
  defaultArm: "grow",
});
