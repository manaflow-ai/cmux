// l10n-allow-file: synthetic gallery fixtures.
import { settingsPageEntry } from "../../gallery/format";

export default settingsPageEntry({
  id: "pages.configuration-check",
  title: "Configuration checker",
  area: "Settings",
  height: 760,
  covers: ["pages/settings/components/ConfigurationCheck.tsx#ConfigurationCheck"],
  variants: {
    clean: { section: "advanced", options: { diagnostics: [] } },
    problems: {
      section: "advanced",
      options: { diagnostics: [{ path: "agent.example", message: "Unknown setting" }] },
    },
    unavailable: {
      section: "advanced",
      options: { failing: { "cmux.settings.snapshot": "unavailable" } },
      steps: [{ selector: "[data-config-check] button", action: "click" }],
    },
  },
});
