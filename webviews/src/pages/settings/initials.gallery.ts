// l10n-allow-file: gallery fixtures (synthetic names), not shipped UI.
import { settingsPageEntry } from "../../gallery/format";

const names = ["Jo", "🦊 Fox", "👩🏽‍💻 Priya", "𠮷田", "e\u0301lodie"];

export default settingsPageEntry({
  id: "pages.settings-initials",
  title: "Settings name initials",
  area: "Settings",
  height: 800,
  covers: ["pages/settings/components/HostSections.tsx"],
  variants: {
    profiles: {
      section: "browser",
      note: "Profiles without icons: a Latin control, emoji, a joined emoji, supplementary CJK and a decomposed accent.",
      host: {
        browser_profiles: names.map((name, index) => ({
          id: `initial-profile-${index}`,
          name,
          icon: null,
          color: null,
          is_default: index === 0,
          source: null,
        })),
      },
      steps: [{ selector: '[data-profile="initial-profile-0"] .host-toggle', action: "focus" }],
    },
    machines: {
      section: "machines",
      note: "The same names reach the machine-row fallback through the host list, with no explicit icons.",
      host: {
        machines: names.map((title, index) => ({
          id: `initial-machine-${index}`,
          title,
          subtitle: null,
          icon: null,
          active: false,
        })),
        devices: undefined,
      },
      steps: [{ selector: '[data-host-row="initial-machine-4"] .host-avatar', action: "wait" }],
    },
  },
});
