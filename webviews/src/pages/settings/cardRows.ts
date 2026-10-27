// The schema rows a card draws itself, so its section (SectionView) and the search leave them out of
// their group lists. They live apart from the cards: the navigation and the group lists are in the
// page's first load, and each card is in its section's chunk (lazySections.ts).
import { useSettingsState } from "./context";

/** The terminal theme (the theme studio draws it). */
export const THEME_KEY = "appearance.theme";
/** The app theme apart from the terminal theme; `followTerminal` (its default) matches it. */
export const APP_THEME_KEY = "appearance.appTheme";
// appearance.themeEdits: per-token color edits, keyed "<theme>/<token>" (ThemeEditsSetting); drawn by
// the theme studio, never as a row.
export const THEME_EDITS_KEY = "appearance.themeEdits";
/** appearance.accent: drawn by the theme studio as the swatch popup, after the app theme. */
export const ACCENT_KEY = "appearance.accent";

export const BACKGROUND_KEY = "appearance.background";
export const BACKGROUND_OPACITY_KEY = "appearance.backgroundOpacity";
/** `appearance.backgroundBlur`: the window's Material, drawn in the card beside Opacity. */
export const MATERIAL_KEY = "appearance.backgroundBlur";
/** `appearance.backgroundRotation`: how often a shuffle turns, shown in the card while one is chosen. */
export const ROTATION_KEY = "appearance.backgroundRotation";
/** The rows the background picker draws, left out of their group while it shows. */
export const BACKDROP_ROWS: ReadonlySet<string> = new Set([
  BACKGROUND_KEY,
  BACKGROUND_OPACITY_KEY,
  MATERIAL_KEY,
  ROTATION_KEY,
]);

/** Whether the background picker draws (the host lists the art); its rows show in their group otherwise. */
export function useBackdropsShown(): boolean {
  return (useSettingsState().host?.backdrops ?? []).length > 0;
}

export const CHIEF_PET_ENABLED = "home.chiefPetEnabled";
export const CHIEF_PET_MASCOT = "home.chiefPetMascot";
export const CHIEF_BUBBLE_STYLE = "home.chiefBubbleStyle";
/** The rows the Chief Pet card draws in place of their group. */
export const CHIEF_PET_ROWS: ReadonlySet<string> = new Set([CHIEF_PET_ENABLED, CHIEF_PET_MASCOT, CHIEF_BUBBLE_STYLE]);

/** `appearance.machineColors`: a machine's color, keyed by its color key. The Machines card draws it,
 * not a map row. */
export const MACHINE_COLORS_KEY = "appearance.machineColors";
