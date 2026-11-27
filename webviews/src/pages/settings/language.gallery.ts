// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > General > Language (`app.language`): the language picker (System and every shipped
// locale, each in its own name) and, while the app's menus still use the language it launched in
// (English here), the Relaunch to update menus and commands row under it.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";

const variant = (value: string, note: string, relaunch: boolean): SettingsPageVariant => ({
  section: "general",
  focus: "app.language",
  options: { values: { "app.language": value } },
  steps: [{ selector: relaunch ? "[data-language-relaunch]" : '[data-row-key="app.language"]', action: "wait" }],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-language",
  title: "Settings Language",
  area: "Settings",
  height: 360,
  covers: ["pages/settings/components/LanguageRelaunchRow.tsx"],
  anchors: [{ selector: '[data-row-key="app.language"]' }],
  variants: {
    english: variant("en", "English, the language the app launched in: no Relaunch row.", false),
    japanese: variant("ja", "日本語 picked: the menus keep English until Relaunch.", true),
    german: variant("de", "Deutsch picked: the Relaunch to update menus and commands row under Language.", true),
  },
});
