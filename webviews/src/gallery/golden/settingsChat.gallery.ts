// The golden Settings page's Chat section under every look (settings.ts): a long section.
// l10n-allow-file: gallery entry title, not shipped UI.
import { settingsPageEntry } from "../format";
import { goldenSettings } from "./settings";

export default settingsPageEntry({
  id: "looks.golden.settings.chat",
  title: "Golden Settings: Chat (every look)",
  ...goldenSettings("chat"),
});
