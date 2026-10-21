// What a theme picker shows for its default choice: "Use Ghostty Config" on the terminal theme
// (appearance.theme) and "Match Terminal Theme" on the app theme (appearance.appTheme). The Theme
// card and the search-result pickers (ThemeRowEditor) resolve them the same way.
import type { GhosttyTheme } from "../../theme/ghosttyTheme";
import { parseThemeSpec, themeFor } from "./themeSpec";

export const DEFAULT_DARK = "Apple System Colors";
export const DEFAULT_LIGHT = "Apple System Colors Light";

/** The built-in theme a light/dark pair falls back to on `scheme`'s side. */
export const fallbackThemeName = (scheme: "light" | "dark") => (scheme === "dark" ? DEFAULT_DARK : DEFAULT_LIGHT);

/** The Ghostty config's own colors (sent by the host while appearance.theme is unset), else the
 * built-in theme for `scheme`. */
export function configThemeColors(
  config: GhosttyTheme | null | undefined,
  colors: ReadonlyMap<string, GhosttyTheme> | null,
  scheme: "light" | "dark",
  label: string,
): GhosttyTheme | undefined {
  return config ? { ...config, name: label } : colors?.get(fallbackThemeName(scheme));
}

/** The colors the terminal shows for appearance.theme's `value` on `scheme`'s side; the config's
 * colors when it is unset or names a theme without published colors. */
export function terminalThemeColors(
  value: unknown,
  colors: ReadonlyMap<string, GhosttyTheme> | null,
  scheme: "light" | "dark",
  config: GhosttyTheme | undefined,
): GhosttyTheme | undefined {
  const spec = parseThemeSpec(value);
  return (spec ? colors?.get(themeFor(spec, scheme, fallbackThemeName(scheme))) : undefined) ?? config;
}
