// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Which glass a stack toast (NoticeStack) draws on (glass-raycast-parity.md "Web popups";
/// design-system-decisions B1: a toast over its surface is a `floating` surface). Settings > Advanced >
/// Experiments > Toast Glass (`experiments.toastGlass`, off by default) runs `host`
/// (experiments/hostSettings.ts SETTING_ARMS); off, every toast draws today's page material.
/// Compare in the gallery: `ui.notice`, variants `glass-page`, `glass-host`, `glass-host-busy`.
export const toastGlass = defineExperiment({
  id: "toast-glass",
  title: "Toast glass",
  description:
    "Which glass a stack toast sits on: the page's floating material, or the App's own toast glass under the page where the App draws it. Look for: legibility over busy text, and a match with the native toasts.",
  arms: {
    page: {
      label: "Page",
      description: "Today's toast: the page's floating material (what a page with no App glass under it draws).",
    },
    host: {
      label: "Host",
      description:
        "Each toast marks data-host-glass (role toast), so the App draws its own toast glass under the card, as its native toasts are drawn; a page with no App glass keeps the floating material.",
    },
  },
  defaultArm: "page",
});

export type ToastGlass = keyof typeof toastGlass.arms;
