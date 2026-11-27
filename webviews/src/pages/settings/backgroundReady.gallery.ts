// l10n-allow-file: gallery fixtures, not shipped UI.
// General > Quitting > Stay Ready in the Background (`app.backgroundReady`, off by default; RFD 0134 Table 4
// row 2, "Pages from disk"). One variant per value, and the menu open with every choice.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";

const key = "app.backgroundReady";
const row = `[data-row-key="${key}"]`;
const click = (selector: string): PageFixtureStep => ({ selector, action: "click" });
const wait = (selector: string): PageFixtureStep => ({ selector, action: "wait" });

const value = (choice: string | undefined, note: string): SettingsPageVariant => ({
  section: "general",
  focus: key,
  steps: [wait(row)],
  note,
  ...(choice === undefined ? {} : { options: { values: { [key]: choice } } }),
});

export default settingsPageEntry({
  id: "pages.settings-background-ready",
  title: "Settings Stay Ready in the Background",
  area: "Settings",
  height: 620,
  covers: ["page:cmux.settings"],
  anchors: [{ selector: row }],
  variants: {
    off: value(undefined, "The default: Off. No quit stays and no launch starts hidden."),
    "warm-at-login": value(
      "warmAtLogin",
      "Warm at Login: at login a reader loads cmux's files from disk once, then exits. Nothing stays running.",
    ),
    "after-quit": value("afterQuit", "After Quit: Quit keeps cmux running hidden, so the next open is instant."),
    "after-quit-and-login": value(
      "afterQuitAndLogin",
      "After Quit and at Login: as After Quit, and cmux also starts hidden at login.",
    ),
    "menu-open": {
      section: "general",
      focus: key,
      steps: [wait(row), click(`${row} .ui-select-button`), wait(".ui-select-popup .ui-menu-item")],
      note: "The menu open: Off, Warm at Login, After Quit, After Quit and at Login.",
    },
  },
});
