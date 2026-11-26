import type { AgentSessionTheme } from "./types";

/** The page's `--agent-*` variable per theme key, null where the key is no variable. Read by the page's
 * theme apply (theme.ts) and by a chat copy drawn under another theme (chatSnapshot/paint.ts), which
 * takes the live theme's colors before the page runs; it imports no more than this. */
export const AGENT_THEME_VARIABLES: Record<keyof AgentSessionTheme, string | null> = {
  isDark: null,
  pageBackground: "--agent-page-bg",
  surfaceBackground: "--agent-surface",
  surfaceElevatedBackground: "--agent-surface-elevated",
  inputBackground: "--agent-input-bg",
  border: "--agent-border",
  borderStrong: "--agent-border-strong",
  text: "--agent-text",
  mutedText: "--agent-muted",
  softText: "--agent-soft",
  accent: "--agent-accent",
  accentSoft: "--agent-accent-soft",
  litGlyph: "--agent-lit-glyph",
  accentText: "--agent-accent-text",
  onAccent: "--agent-on-accent",
  danger: "--agent-danger",
  warning: "--agent-warning",
  success: "--agent-success",
  highlight: "--agent-highlight",
  highlightText: "--agent-highlight-text",
  shadow: "--agent-shadow",
  palette: null,
  borders: null,
  focusRingEnabled: null,
  toolRunLook: null,
  turnActionsPlacement: null,
  motion: null,
  statusIndicators: null,
  workingLook: null,
  slots: null,
  subagentTrayPlacement: null,
};

/** The `--agent-*` colors `theme` sets, the 16 `--agent-ansi-N` included: each variable with its value,
 * or undefined where the theme leaves it out (the page then removes the variable). */
export function agentThemeColors(theme: Partial<AgentSessionTheme>): Array<[string, string | undefined]> {
  const colors: Array<[string, string | undefined]> = [];
  for (const [key, variable] of Object.entries(AGENT_THEME_VARIABLES) as Array<
    [keyof AgentSessionTheme, string | null]
  >) {
    if (!variable) continue;
    const value = theme[key];
    colors.push([variable, value === undefined ? undefined : String(value)]);
  }
  for (let index = 0; index < 16; index += 1)
    colors.push([`--agent-ansi-${index}`, theme.palette?.[index] || undefined]);
  return colors;
}
