// The schema rows each card draws itself, so SectionView can leave them out of their groups
// without importing the card. The cards load on demand (components/cardModules.tsx); these keys
// stay in the page's startup script, the card's code and art do not.
import { useSettingsState } from "./context";
import { DARK_KEY, DYNAMIC_KEY, LIGHT_KEY, LOCATION_KEY, SCHEDULE_KEY } from "./wallpaperSwitch";

export const CHIEF_PET_ENABLED = "home.chiefPetEnabled";
export const CHIEF_PET_MASCOT = "home.chiefPetMascot";
export const CHIEF_BUBBLE_STYLE = "home.chiefBubbleStyle";
/** The bubble colors every chat starts with (`HomeBubbleColorsSetting`), in the schema's order. */
export const CHIEF_BUBBLE_COLORS: readonly string[] = ["sent", "sentText", "received", "receivedText"].map(
  (role) => `home.bubbleColors.${role}`,
);
/** Whether the main Chief's chat shows the Feed's notices (`HomeFeedRowsSetting`). */
export const CHIEF_FEED_IN_CHIEF = "home.feedInChief";
/** The rows the Chief Pet card draws in place of their group. */
export const CHIEF_PET_ROWS: ReadonlySet<string> = new Set([
  CHIEF_PET_ENABLED,
  CHIEF_PET_MASCOT,
  CHIEF_BUBBLE_STYLE,
  ...CHIEF_BUBBLE_COLORS,
  CHIEF_FEED_IN_CHIEF,
]);

export const CHIEF_ENGINE = "home.chiefEngine";
/** The rows the Chiefs card draws in place of their group. */
export const CHIEFS_ROWS: ReadonlySet<string> = new Set([CHIEF_ENGINE]);

export const COMPUTER_USE_MODE = "computerUse.mode";
export const COMPUTER_USE_DENIED_APPS = "computerUse.deniedApps";
/** Whether agents may open menus of background apps (a choice row, drawn before the switches). */
export const COMPUTER_USE_MENUS = "computerUse.menus";
/** The switches and pickers under the approvals, in the card's order: the agent cursor's tag and
 * what agents wait for after each action follow Show Agent Cursor; Allow Foreground Input
 * (advanced) comes last. */
export const COMPUTER_USE_SWITCHES = [
  "computerUse.allowOwnMachines",
  "computerUse.pauseOnTakeover",
  "computerUse.showCursor",
  "computerUse.cursorTag",
  "computerUse.settle",
  "computerUse.livePreview",
  "computerUse.whileLocked",
  "computerUse.allowForeground",
] as const;
/** The schema rows the Computer Use card draws itself. */
export const COMPUTER_USE_ROWS: ReadonlySet<string> = new Set([
  COMPUTER_USE_MODE,
  COMPUTER_USE_DENIED_APPS,
  COMPUTER_USE_MENUS,
  ...COMPUTER_USE_SWITCHES,
]);

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
  // Switch Automatically's keys: its editors draw them.
  LIGHT_KEY,
  DARK_KEY,
  SCHEDULE_KEY,
  DYNAMIC_KEY,
  LOCATION_KEY,
]);

/** Whether the background picker draws (the host lists the art); its rows show in their group otherwise. */
export function useBackdropsShown(): boolean {
  return (useSettingsState().host?.backdrops ?? []).length > 0;
}

/** `appearance.machineColors`: a machine's color, keyed by its color key. The card draws it, not a map row. */
export const MACHINE_COLORS_KEY = "appearance.machineColors";

export const THEME_KEY = "appearance.theme";
/** The app theme apart from the terminal theme; `followTerminal` (its default) matches it. */
export const APP_THEME_KEY = "appearance.appTheme";
// appearance.themeEdits: per-token color edits, keyed "<theme>/<token>" (ThemeEditsSetting); drawn here, not as a row.
export const THEME_EDITS_KEY = "appearance.themeEdits";
/** appearance.accent: drawn here as the swatch popup, after the app theme. */
export const ACCENT_KEY = "appearance.accent";
/** appearance.highlightColor: drawn here as its setting row, after the accent (the App Theme group's
 * last key: without it the page drew a second "App Theme" card for this one row). */
export const HIGHLIGHT_COLOR_KEY = "appearance.highlightColor";
/** appearance.rotateFavoriteThemes: drawn here as its setting row under the terminal theme, once a
 * theme is starred (its App Theme group would draw a second card). */
export const ROTATE_FAVORITES_KEY = "appearance.rotateFavoriteThemes";
/** appearance.themeFile: the look from a file in the themes folder, drawn here as its setting row
 * after the Highlight Color (another App Theme key: its group would draw a second card for it). */
export const THEME_FILE_KEY = "appearance.themeFile";
/** appearance.favoriteThemes: the starred themes, shared by every theme picker on the page. */
export const FAVORITE_THEMES_KEY = "appearance.favoriteThemes";

/** The schema rows about spaces (Sidebar > Sidebar Buttons and Spaces). With one space the page
 * draws none of them (Hide Spaces); search still finds them. */
export const SPACE_ROWS: ReadonlySet<string> = new Set([
  "sidebar.showSpaces",
  "sidebar.spacesPosition",
  "sidebar.spacesVisibility",
]);

/** Whether the active window has a second space: until then no Settings page names spaces. */
export function useSeveralSpaces(): boolean {
  const { host } = useSettingsState();
  return (host?.rooms?.length ?? 0) > 1;
}
