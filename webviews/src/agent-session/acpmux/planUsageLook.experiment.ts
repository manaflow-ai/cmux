// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the composer ring's plan usage popover lays out the account's limits (Leo, 2026-11-04: "i
/// guess we can turn that into a 5h/weekly usage type thing instead as well for some people", with
/// Codex's and Claude desktop's ring popovers). Gallery `agent-pane.plan-usage-card`.
export const planUsageLook = defineExperiment({
  id: "plan-usage-look",
  title: "Plan usage popover",
  description:
    "How the ring's plan usage popover shows the 5-hour and weekly limits and credits. Every arm reads only what the harness reported.",
  arms: {
    "claude-bars": {
      label: "Bars (Claude desktop)",
      description:
        "Plan usage limits · plan on top; each window's name, reset time and percent used on one line with a bar under it.",
    },
    "codex-rows": {
      label: "Rows (Codex)",
      description: "Usage source: your plan, then one row per window with the share left, and credits; no bars.",
    },
    compact: {
      label: "Compact",
      description: "One line per window: name, a short inline bar and the percent used; the reset time under it.",
    },
  },
  defaultArm: "claude-bars",
});
