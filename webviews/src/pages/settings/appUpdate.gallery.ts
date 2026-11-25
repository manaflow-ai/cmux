// l10n-allow-file: gallery fixtures, not shipped UI.
// Updates > App Update (AppUpdateCard): the app update's status, from the host lists' `app_update`.
// The sidebar shows no download (Leo 2026-11-03, after ChatGPT's one-step update), so this card
// carries the progress, Cancel, Restart to Update and a failure's Try Again. One variant per state.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { AppUpdateState } from "./ops";

const idle: AppUpdateState = {
  title: "App Update",
  phase: "idle",
  status: "You have 1.0.0-nightly.3913596493801.",
  detail: null,
  actions: [{ id: "check", title: "Check Now", prominent: false }],
};
const card = (phase: string): PageFixtureStep => ({
  selector: `[data-card="app-update"][data-phase="${phase}"]`,
  action: "wait",
});
const variant = (state: AppUpdateState, note: string): SettingsPageVariant => ({
  section: "updates",
  host: { app_update: state },
  steps: [card(state.phase)],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-app-update",
  title: "Settings App Update",
  area: "Settings",
  height: 520,
  covers: ["pages/settings/components/AppUpdateCard.tsx"],
  anchors: [{ selector: '[data-card="app-update"]' }],
  variants: {
    idle: variant(idle, "Nothing runs: the running version and Check Now."),
    downloading: variant(
      {
        ...idle,
        phase: "downloading",
        status: "Downloading Update",
        detail: "57.3 MB of 257.1 MB · 22%",
        progress: 0.22,
        actions: [{ id: "cancel_download", title: "Cancel", prominent: false }],
      },
      "A download, background or asked for: its bytes, the bar and Cancel (the sidebar shows none).",
    ),
    ready: variant(
      {
        ...idle,
        phase: "ready",
        status: "Update Ready",
        detail: "Version 1.0.0-nightly.3913596493802",
        actions: [{ id: "install", title: "Restart to Update", prominent: true }],
      },
      "Staged: one Restart to Update, the same click as the sidebar's ready card.",
    ),
    failed: variant(
      {
        ...idle,
        phase: "check_failed",
        status: "Update Check Failed",
        detail: "The network connection was lost.",
        actions: [{ id: "retry", title: "Try Again", prominent: false }],
      },
      "A failed check or download, background ones too: the cause and Try Again.",
    ),
  },
});
