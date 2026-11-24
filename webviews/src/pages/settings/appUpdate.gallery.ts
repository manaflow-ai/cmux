// l10n-allow-file: gallery fixtures, not shipped UI.
// Updates > App Update (AppUpdateCard): the app update's status, from the host lists' `app_update`.
// The sidebar shows no download (Leo 2026-11-03, after ChatGPT's one-step update), so this card
// carries the progress, Cancel, Restart to Update and a failure's Try Again. One variant per state.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { AppUpdateState, PreviousBuild } from "./ops";

const idle: AppUpdateState = {
  title: "App Update",
  phase: "idle",
  status: "You have 1.0.0-nightly.3913596493801.",
  detail: null,
  actions: [{ id: "check", title: "Check Now", prominent: false }],
  schedule: [
    { id: "lastUpdated", label: "Last Updated", value: "Today at 9:12 PM" },
    { id: "nextCheck", label: "Next Check", value: "Today at 10:12 PM" },
  ],
};
const previousBuild = (refusal: string | null): PreviousBuild => ({
  build: "3913596493800",
  version: "1.0.0-nightly.3913596493800",
  date: "2026-11-20",
  commit: "d7ce54c2",
  commit_url: "https://github.com/manaflow-ai/cmux/commit/d7ce54c2272",
  title: "Go Back to Previous Build",
  action: "Go Back",
  detail: "Restarts once into 1.0.0-nightly.3913596493800, kept on this Mac. Settings and sessions stay.",
  build_label: "Build 3913596493800",
  refusal,
});
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
  covers: ["pages/settings/components/AppUpdateCard.tsx", "pages/settings/components/PreviousBuildRow.tsx"],
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
    "previous-build": {
      section: "updates",
      host: { app_update: idle },
      options: { previousBuild: previousBuild(null) },
      steps: [card("idle"), { selector: "[data-previous-build]", action: "wait" }],
      note: "Go Back to Previous Build: the kept build's number, day and commit, and its Go Back.",
    },
    "previous-build-refused": {
      section: "updates",
      host: { app_update: idle },
      options: {
        previousBuild: previousBuild(
          "1.0.0-nightly.3913596493800 cannot read this Mac's sessions store (it is newer). Your data stays safe here.",
        ),
      },
      steps: [card("idle"), { selector: "[data-previous-build][data-refused]", action: "wait" }],
      note: "The rollback would refuse: Go Back is off and the host's reason shows.",
    },
  },
});
