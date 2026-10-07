// What the app hands each web page for a theme, from the same tokens:
//   - WebTheme.swift: the shared `--cmux-*` variables (`window.cmuxTheme.apply` payload);
//   - AgentPaneTheme.swift: the agent pane's `AgentSessionTheme` (`cmuxAcpmuxBridge.applyTheme`);
//   - the diff viewer and markdown appearance (`DiffViewerAppearance`, appearance.ts), which
//     carries the Ghostty theme pair itself.
// The window is opaque here (background-opacity 1, WindowBackdrop.panesPaintBackground), and
// borders draw lines (appearance.borders lines), as by default.
import type { DiffViewerAppearance, DiffViewerTheme } from "../../appearance";
import type { GhosttyTheme } from "./ghostty";
import { appThemeVariables, type AppTheme } from "../../theme/appTheme";
import {
  css,
  deriveTokens,
  GHOSTTY_DEFAULT,
  MINIMUM_TEXT_CONTRAST,
  parseHex,
  readable,
  withAlpha,
  type ThemeInput,
  type ThemeTokens,
} from "./tokens";

export function themeInput(theme: GhosttyTheme): ThemeInput {
  const color = (hex: string | null | undefined) => (hex ? parseHex(hex) : null);
  // ThemeBridge passes the entries Ghostty reports; a theme always reports 16 (its own or the
  // defaults under them), so a gap takes Ghostty's default color.
  const palette = theme.palette.map((hex, index) => color(hex) ?? GHOSTTY_DEFAULT.palette[index]!);
  return {
    background: color(theme.background) ?? GHOSTTY_DEFAULT.background,
    foreground: color(theme.foreground) ?? GHOSTTY_DEFAULT.foreground,
    palette,
    selectionBackground: color(theme.selectionBackground) ?? undefined,
    selectionForeground: color(theme.selectionForeground) ?? undefined,
    backgroundOpacity: 1,
  };
}

export const themeTokens = (theme: GhosttyTheme): ThemeTokens => deriveTokens(themeInput(theme));

/** WebTheme(tokens).payload: `{variables, colorScheme, scrollers}`; with `app`, also the app
 * theme's `--cmux-app-*` tokens (WebTheme sends them from CmuxTheme's AppTheme, the same contract). */
export function webThemePayload(
  tokens: ThemeTokens,
  app?: AppTheme,
): {
  variables: Record<string, string>;
  colorScheme: "dark" | "light";
  scrollers: "overlay" | "legacy";
} {
  const page = withAlpha(tokens.surfaceBackground, 1);
  return {
    variables: {
      "--cmux-surface-background": css(page),
      "--cmux-surface-token": css(tokens.surfaceBackground),
      "--cmux-elevated-background": css(tokens.elevatedBackground),
      "--cmux-text": css(tokens.textPrimary),
      "--cmux-text-secondary": css(tokens.textSecondary),
      "--cmux-text-tertiary": css(tokens.textTertiary),
      "--cmux-separator": css(tokens.separator),
      "--cmux-hover": css(tokens.hoverFill),
      "--cmux-selection": css(tokens.selectionFill),
      ...(app ? appThemeVariables(app) : {}),
    },
    colorScheme: tokens.isDark ? "dark" : "light",
    scrollers: "overlay",
  };
}

/** The pane's fade durations in seconds (MotionTunables.swift); under Reduce Motion each is at
 * most one crossfade (MotionPolicy.duration). */
const MOTION = { hover: 0.08, focus: 0.1, fadeIn: 0.12, fadeOut: 0.08 } as const;
const CROSSFADE = 0.1;

/** AgentPaneTheme.values(tokens). */
export function agentPaneTheme(tokens: ThemeTokens, reducedMotion: boolean): Record<string, unknown> {
  const page = withAlpha(tokens.surfaceBackground, 1);
  const opaquePage = withAlpha(tokens.contentBackground, 1);
  const motion = Object.fromEntries(
    Object.entries(MOTION).map(([key, seconds]) => [key, reducedMotion ? Math.min(seconds, CROSSFADE) : seconds]),
  );
  return {
    isDark: tokens.isDark,
    pageBackground: css(page),
    surfaceBackground: css(page),
    surfaceElevatedBackground: css(tokens.elevatedBackground),
    inputBackground: css(tokens.hoverFill),
    border: css(tokens.separator),
    borderStrong: css(tokens.paneBorder),
    borders: "lines",
    text: css(tokens.textPrimary),
    mutedText: css(tokens.textSecondary),
    softText: css(tokens.textTertiary),
    accent: css(tokens.textPrimary),
    accentSoft: css(tokens.selectionFill),
    accentText: css(opaquePage),
    danger: css(tokens.danger),
    warning: css(tokens.attention),
    highlight: css(tokens.highlight),
    highlightText: css(tokens.highlightText),
    shadow: css(tokens.shadow),
    palette: tokens.ansi
      .slice(0, 16)
      .map((color) => css(readable(color, tokens.elevatedBackground, MINIMUM_TEXT_CONTRAST))),
    motion,
  };
}

function diffTheme(theme: GhosttyTheme, type: "dark" | "light"): DiffViewerTheme {
  const palette: Record<string, string> = {};
  theme.palette.forEach((hex, index) => {
    if (hex) palette[String(index)] = hex;
  });
  return {
    background: theme.background,
    foreground: theme.foreground,
    ghosttyName: theme.name,
    name: `cmux-ghostty-${type}`,
    palette,
    selectionBackground: theme.selectionBackground,
    selectionForeground: theme.selectionForeground,
    type,
  };
}

/** The appearance the app sends the diff viewer and the markdown page for a theme pair. */
export function diffAppearance(
  pair: { dark: GhosttyTheme; light: GhosttyTheme },
  font: { family?: string; size?: number },
): DiffViewerAppearance {
  return {
    backgroundOpacity: 1,
    fontFamily: font.family,
    fontSize: font.size,
    // `theme` names the registered syntax themes (cmux-ghostty-dark/-light, from `themes`); the
    // Ghostty names travel as each theme's `ghosttyName`.
    themes: { dark: diffTheme(pair.dark, "dark"), light: diffTheme(pair.light, "light") },
  };
}
