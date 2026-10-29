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
    "The tray's entrance and exit: the new message's own rise, a tight fade, or a rise with a slight spring.",
  arms: {
    message: {
      label: "Like a message",
      description:
        "The live transcript row's entrance (cv-enter: fade and a 4px rise on --agent-motion-in and --agent-ease-out); out on --agent-motion-out.",
    },
    tight: {
      label: "Tight fade",
      description: "Opacity only, on the micro step (120 ms) easing out; out on the quick step.",
    },
    spring: {
      label: "Slight spring",
      description:
        "An 8px rise from 98% scale on the standard step (180 ms) with a small overshoot; out on the quick step.",
    },
  },
  defaultArm: "message",
});
