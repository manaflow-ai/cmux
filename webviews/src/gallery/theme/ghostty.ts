// The gallery's Ghostty themes: the shared parser (src/theme/ghosttyTheme.ts), whether a theme is
// dark, and the app's default pair.

export { parseGhosttyTheme, type GhosttyTheme } from "../../theme/ghosttyTheme";
import type { GhosttyTheme } from "../../theme/ghosttyTheme";

/** Whether a theme is dark: its background is darker than its foreground (ThemeTokens.isDark). */
export function themeIsDark(theme: GhosttyTheme): boolean {
  const lum = (hex: string) => {
    const value = parseInt(hex.slice(1), 16);
    const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
    return (
      0.2126 * linear(((value >> 16) & 0xff) / 255) +
      0.7152 * linear(((value >> 8) & 0xff) / 255) +
      0.0722 * linear((value & 0xff) / 255)
    );
  };
  return lum(theme.background) < lum(theme.foreground);
}

/** The app's default pair (appearance.ts): Apple System Colors, dark and light. */
export const DEFAULT_DARK_THEME = "Apple System Colors";
export const DEFAULT_LIGHT_THEME = "Apple System Colors Light";
