// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry } from "../../gallery/format";

export default settingsPageEntry({
  id: "pages.settings-remote-hosts",
  title: "Settings Remote Workspaces",
  area: "Settings",
  height: 720,
  covers: ["pages/settings/components/RemoteHostsExperiment.tsx"],
  variants: {
    off: {
      section: "devices",
      note: "Default: the remote-workspace experiment is absent and no host connection starts.",
    },
    enabled: {
      section: "devices",
      options: { values: { "labs.previewFeatures": true } },
      steps: [{ selector: '[data-devices-group="remote-hosts"]', action: "wait" }],
      note: "Labs preview enabled: one standard Settings row opens the existing native host picker.",
    },
    refused: {
      section: "devices",
      options: { values: { "labs.previewFeatures": true }, actionRan: false },
      steps: [{ selector: "[data-remote-hosts-connect]", action: "click" }],
      note: "A refused picker shows an error in the row and the button remains available for retry.",
    },
  },
});
