// l10n-allow-file: gallery notes, not shipped UI.
import { settingsPageEntry } from "../../gallery/format";

export default settingsPageEntry({
  id: "pages.settings-controls",
  title: "Settings shared controls",
  area: "Settings",
  height: 760,
  widths: { narrow: 480, normal: 1000, wide: 1440 },
  covers: [
    "pages/settings/editors/ToggleEditor.tsx",
    "pages/settings/editors/TextEditor.tsx",
    "pages/settings/editors/NumberField.tsx",
    "pages/settings/components/ResetButton.tsx",
    "pages/settings/components/AgentHarnesses.tsx",
  ],
  variants: {
    standard: {
      section: "privacy",
      focus: "history.terminalCommands",
      note: "Real setting switch and reserved Reset slot.",
    },
    text: {
      section: "browser",
      focus: "browser.newTabPage",
      note: "Text commits, validation and reset on the real settings store.",
    },
    managed: {
      section: "browser",
      focus: "browser.remoteLocalhost",
      note: "Organization-managed switch remains disabled.",
    },
    number: {
      section: "appearance",
      focus: "terminal.fontSize",
      note: "Intrinsic number field and slider retain their shared row.",
    },
    tabs: { section: "agents", focus: "agents.add", note: "Registry and Custom panels use shared Tabs." },
  },
});
