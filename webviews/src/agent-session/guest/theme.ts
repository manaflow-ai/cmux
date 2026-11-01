// The guest page's colors: the pane's theme variables (shared/theme.ts) in a neutral light or dark
// set, following the browser's color scheme as it changes. A guest has no terminal theme.
import { applyAgentTheme } from "../shared/theme";
import type { AgentSessionTheme } from "../shared/types";

const LIGHT: AgentSessionTheme = {
  isDark: false,
  pageBackground: "#ffffff",
  surfaceBackground: "#f7f7f7",
  surfaceElevatedBackground: "#ffffff",
  inputBackground: "#fafafa",
  border: "#e2e2e2",
  borderStrong: "#c4c4c4",
  text: "#1d1d1f",
  mutedText: "#6e6e73",
  softText: "#48484a",
  accent: "#1d1d1f",
  accentSoft: "#ececec",
  onAccent: "#ffffff",
  accentText: "#ffffff",
  danger: "#c4314b",
  shadow: "#00000022",
};

const DARK: AgentSessionTheme = {
  isDark: true,
  pageBackground: "#161616",
  surfaceBackground: "#1f1f1f",
  surfaceElevatedBackground: "#282828",
  inputBackground: "#111111",
  border: "#333333",
  borderStrong: "#4d4d4d",
  text: "#f2f2f2",
  mutedText: "#a1a1a1",
  softText: "#c4c4c4",
  accent: "#f2f2f2",
  accentSoft: "#2e2e2e",
  onAccent: "#161616",
  accentText: "#161616",
  danger: "#ff6b6b",
  shadow: "#00000088",
};

/** The theme for the browser's scheme now. */
export const browserTheme = (dark: boolean): AgentSessionTheme => (dark ? DARK : LIGHT);

/** Applies the browser's light or dark, and again whenever it changes. */
export function followBrowserTheme(media = window.matchMedia("(prefers-color-scheme: dark)")): void {
  applyAgentTheme(browserTheme(media.matches));
  media.addEventListener("change", (event) => applyAgentTheme(browserTheme(event.matches)));
}
