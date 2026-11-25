// The golden Settings page's Appearance section under every look (settings.ts).
// l10n-allow-file: gallery entry title, not shipped UI.
import { settingsPageEntry } from "../format";
import { goldenSettings } from "./settings";

export default settingsPageEntry({
  id: "looks.golden.settings.appearance",
  title: "Golden Settings: Appearance (every look)",
  ...goldenSettings("appearance"),
});
