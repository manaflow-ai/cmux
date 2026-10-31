// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Hover actions (Leo dogfood 2026-10-13: "hover buttons everywhere"): a row shows at most one
/// action on hover, and the rest move to its right-click menu and keys. "all" keeps every hover
/// action, for comparison: set `cmux.experiments` to `{"hover-actions":"all"}` in the pane's web
/// inspector and reload. A queued prompt's row shows all its actions in both arms (Leo, 2026-10-20).
export const hoverActions = defineExperiment({
  id: "hover-actions",
  title: "Hover actions",
  description:
    "How many buttons a row shows on hover: a prompt's Copy and Edit, a call output's Copy, a channel message's reactions, Reply and More.",
  arms: {
    all: { label: "All", description: "Every action shows on hover, as before." },
    one: {
      label: "One",
      description: "One action on hover (a prompt's Edit, a message's More); the rest are on right-click and keys.",
    },
  },
  defaultArm: "one",
});
