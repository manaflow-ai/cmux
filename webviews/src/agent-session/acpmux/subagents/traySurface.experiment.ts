// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The headed tray's own surface (SubagentTray.tsx) while nothing runs. #29276 took the card away
/// from a settled tray, so its header and lines sat on the chat's own glass and read as part of it
/// (Leo, 2026-11-01: "you fucking glassed way too hard now there's no difference at all" and "i mean
/// you can't just have it be the exact same glass as the background"). Every arm stays see-through
/// (never opaque) and keeps the composer's rounded join; they differ in how much the fill and the rim
/// set it apart. A lone ended line (no header) stays quiet in every arm. Compare them in the
/// gallery's `agent-pane.subagent-tray` (`settled-surface`).
export const traySurfaceLook = defineExperiment({
  id: "subagent-tray-surface",
  title: "Settled tray surface",
  description:
    "A settled tray's glass: a faint tint with a hairline rim, the hairline rim alone, the running tray's card, or no surface (the look Leo rejected).",
  arms: {
    tint: {
      label: "Faint tint and rim",
      description: "The theme's text at 5% over the chat, with the composer's hairline rim.",
    },
    rim: {
      label: "Rim only",
      description: "A 2% tint, set apart mostly by the composer's hairline rim.",
    },
    card: {
      label: "Running card",
      description: "The running tray's card: the theme's text at 8% with the hairline rim.",
    },
    none: {
      label: "No surface",
      description: "No fill and no rim: the chat's own glass, for comparison (rejected 2026-11-01).",
    },
  },
  defaultArm: "tint",
});
