// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Which glass a dialog or sheet the page draws (ui/Dialog.tsx, a `.ui-glass` popup) sits on (hq RFD
/// "Native or our own web view, per surface", build item 4; design-system-decisions B1: a dialog over its
/// surface is a `floating` surface, its glass the system's). Settings > Advanced > Experiments > Dialog
/// Glass (`experiments.dialogGlass`, off by default) runs `host` (experiments/hostSettings.ts
/// SETTING_ARMS); off, every dialog draws today's page veil and blur (popupSurface.css, THE SHEET ROLE).
/// Compare in the gallery: `ui.dialog`, variants `glass-page`, `glass-host`, `glass-host-busy`.
export const dialogGlass = defineExperiment({
  id: "dialog-glass",
  title: "Dialog glass",
  description:
    "Which glass a dialog or sheet sits on: the page's own veil and blur, or the App's sheet glass (the native dialog card's) under the page where the App draws it. Look for: legibility over busy text, and a match with the native dialogs.",
  arms: {
    page: {
      label: "Page",
      description: "Today's dialog: the page's sheet veil and blur (what a page with no App glass under it draws).",
    },
    host: {
      label: "Host",
      description:
        "Each glass dialog marks data-host-glass (role sheet), so the App draws its native dialog card glass under it; a page with no App glass keeps its own veil and blur.",
    },
  },
  defaultArm: "page",
});

export type DialogGlass = keyof typeof dialogGlass.arms;
