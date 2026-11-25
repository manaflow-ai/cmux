// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Which glass the web find pill (ui/FindPill.tsx, findPill.css) sits on (hq RFD "Native or our own web
/// view, per surface", build item 5). Settings > Advanced > Experiments > Find Pill Glass
/// (`experiments.findPillGlass`, off by default) runs `host` (experiments/hostSettings.ts SETTING_ARMS);
/// off, every find pill draws today's own tint and blur. Compare in the gallery: `ui.find-pill`, variants
/// `glass-page`, `glass-host`, `glass-host-busy`.
export const findPillGlass = defineExperiment({
  id: "find-pill-glass",
  title: "Find pill glass",
  description:
    "Which glass the find pill sits on: its own tooltip tint and blur, or the App's tooltip glass under the page where the App draws it. Look for: the query and count legible over busy text, and a match with the terminal's and the browser's native pill.",
  arms: {
    page: {
      label: "Page",
      description: "Today's pill: its own tooltip tint, blur and rim (what a page with no App glass under it draws).",
    },
    host: {
      label: "Host",
      description:
        "The pill marks data-host-glass (level chip), so the App draws its tooltip glass under it; a page with no App glass keeps the pill's own tint and blur.",
    },
  },
  defaultArm: "page",
});

export type FindPillGlass = keyof typeof findPillGlass.arms;
