// Seven Settings Pages (`appearance.settingsPages`, Settings > Customize, off by default): with the
// opt-in on, the sidebar draws seven pages (categories.ts settingsPageSections) instead of the
// export's titled runs and More, and a search result's title gets its page as a crumb ("AI ›
// Agents"). Off, the page is unchanged.
import { useSettingsSelector } from "./context";
import { valueOf } from "./store";

export const SETTINGS_PAGES_KEY = "appearance.settingsPages";

/** True while the opt-in is on; the sidebar renders again only when it flips. */
export function useSettingsPages(): boolean {
  return useSettingsSelector((state) => valueOf(state, SETTINGS_PAGES_KEY) === true);
}
