// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";

const key = "experiments.nightly_live_updates";
const row = `[data-row-key="${key}"]`;
const variant = (enabled: boolean, managed = false): SettingsPageVariant => ({
  section: "updates",
  focus: key,
  host: { nightly_daemon_updates_available: true },
  options: {
    values: { [key]: enabled },
    managed: managed ? { [key]: { value: enabled, source: "profile", reason: "Set by your organization" } } : {},
  },
  steps: [{ selector: `${row} [role="switch"][aria-checked="${enabled}"]`, action: "wait" }],
});

export default settingsPageEntry({
  id: "pages.settings-nightly-daemon-updates",
  title: "Nightly Live Daemon Updates",
  area: "Settings",
  covers: ["page:cmux.settings"],
  anchors: [{ selector: row }],
  variants: { default: variant(false), enabled: variant(true), managed: variant(false, true) },
});
