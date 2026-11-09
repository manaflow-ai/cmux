// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the tray of running work (SubagentTray.tsx) comes and goes (Leo 2026-10-26: "Like why is this
/// not animating and, like, following along with the exact same things as everything else?"). Every
/// arm eases the card in when the first subagent starts, out on a kept snapshot when the last line
/// goes (trayMotion.ts), folds its list on the shared fold, and ticks its count; they differ in the
/// card's own entrance and exit. Compare them in the gallery's `agent-pane.subagent-tray-motion`.
export const trayMotionLook = defineExperiment({
  id: "subagent-tray-motion",
  title: "Subagent tray motion",
  description:
    "The tray's entrance and exit: the house settle (a fade and a short rise, no overshoot) or a tight fade.",
  arms: {
    message: {
      label: "Settle",
      description:
        "A fade and a 4px rise on the house settle (--cmux-ease-settle over --cmux-motion-settle: cubic-bezier(0.16, 1, 0.3, 1), 265 ms, no overshoot); out quicker on --agent-motion-out.",
    },
    tight: {
      label: "Tight fade",
      description: "Opacity only, on the micro step (120 ms) easing out; out on the quick step.",
    },
  },
  defaultArm: "message",
});
