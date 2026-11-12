// What the app hands each web page for a theme, from the same tokens:
//   - WebTheme.swift: the shared `--cmux-*` variables (`window.cmuxTheme.apply` payload);
//   - AgentPaneTheme.swift: the agent pane's `AgentSessionTheme` (`cmuxAcpmuxBridge.applyTheme`);
//   - the diff viewer and markdown appearance (`DiffViewerAppearance`, appearance.ts), which
//     carries the Ghostty theme pair itself.
// The window is opaque (background-opacity 1, WindowBackdrop.panesPaintBackground) unless the
// gallery's background axis puts a picture behind it (`seeThrough`): then, as over the user's
// picture in the app, the page background is clear and the window's tint over the picture shows
// through (frame/background.ts paints both). Borders draw lines (appearance.borders lines), as by
// default. The title area tone (appearance.titleAreaTone) is One Color unless the env says Subtle
// Tone, on the default flush-corner frame at a title area contrast of 1.
import type { DiffViewerAppearance, DiffViewerTheme } from "../../appearance";
import type { GhosttyTheme } from "./ghostty";
import { appThemeVariables, type AppAccent, type AppTheme } from "../../theme/appTheme";
import { cardMaterial, OPAQUE_OVERLAY_LIFT, scrim, tooltipSurface } from "./overlays";
import type { TitleAreaToneName } from "../env";
import {
  BLACK,
  css,
  deriveTokens,
  GHOSTTY_DEFAULT,
  hex,
  litGlyph,
  opaqueOverlayFill,
  MINIMUM_TEXT_CONTRAST,
  parseHex,
  readable,
  withAlpha,
  type ThemeInput,
  type ThemeTokens,
} from "./tokens";

export function themeInput(theme: GhosttyTheme, accent: AppAccent = "neutral"): ThemeInput {
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
    accent,
    // The theme's own `# cmux-accent`, which wins over `accent` as ThemeBridge's does in the app.
    accentColor: color(theme.accent),
  };
}

export const themeTokens = (theme: GhosttyTheme, accent: AppAccent = "neutral"): ThemeTokens =>
  deriveTokens(themeInput(theme, accent));

/** ChromeTunables.dividerStrength's default: the chrome's divider is the separator's alpha times this. */
export const CHROME_DIVIDER_STRENGTH = 1.75;
/** ChromeTunables.mainPaneShadeLight / Dark's defaults: the flush corner's frame shade (black's alpha). */
export const FLUSH_CORNER_SHADE = { light: 0.045, dark: 0.28 } as const;
/** TitleAreaTone.subtleShare: Subtle Tone's share of the flush corner's shade at a title area contrast of 1. */
export const SUBTLE_TONE_SHARE = 0.5;
/** Metrics.folderTabMinimumShade: under this chrome shade the selected tab keeps the selection fill. */
export const FOLDER_TAB_MINIMUM_SHADE = 0.011;

/** Metrics.mainPaneChromeShade on the default flush corner: 0 under One Color, half the corner's
 * shade under Subtle Tone. */
export const chromeShade = (tokens: ThemeTokens, tone: TitleAreaToneName = "one-color"): number =>
  tone === "subtle-tone" ? (tokens.isDark ? FLUSH_CORNER_SHADE.dark : FLUSH_CORNER_SHADE.light) * SUBTLE_TONE_SHARE : 0;

/** Palette.chromeDivider: the separator with its alpha scaled by the divider strength, at most 1. */
export const chromeDivider = (tokens: ThemeTokens) =>
  withAlpha(tokens.separator, Math.min(1, tokens.separator.alpha * CHROME_DIVIDER_STRENGTH));

/** WebTheme(tokens).payload: `{variables, colorScheme, scrollers, terminal, transition, motion, glass,
 * ...}`; with `app`, also the app
 * theme's `--cmux-app-*` tokens (WebTheme sends them from CmuxTheme's AppTheme, the same contract).
 * `seeThrough`: the window shows a picture behind its material, so the page background is the
 * surface at alpha 0 (WebTheme.pageBackground where panes do not paint), the solid surface stays. */
export function webThemePayload(
  tokens: ThemeTokens,
  app?: AppTheme,
  seeThrough = false,
  options: WebThemeOptions = {},
): WebThemePayload {
  const page = withAlpha(tokens.surfaceBackground, 1);
  const lines = (options.borders ?? "lines") === "lines";
  const tooltip = tooltipSurface(tokens);
  const card = cardMaterial(tokens);
  const divider = lines ? css(chromeDivider(tokens)) : "transparent";
  const shade = chromeShade(tokens, options.titleAreaTone);
  const toned = shade >= FOLDER_TAB_MINIMUM_SHADE;
  return {
    variables: {
      "--cmux-surface-background": css(seeThrough ? withAlpha(page, 0) : page),
      "--cmux-surface-token": css(tokens.surfaceBackground),
      "--cmux-surface-solid": css(page),
      // Reading pages (the Markdown viewer): clear over a picture, else opaque (WebTheme's rule).
      "--cmux-reading-background": css(seeThrough ? withAlpha(page, 0) : page),
      "--cmux-elevated-background": css(tokens.elevatedBackground),
      // Menus', popovers' and tooltips' solid surface, the tooltip's frosted tint and ink, cards'
      // material and rim, and the modal scrim: the same values WebTheme.swift sends (overlays.ts).
      "--cmux-popup-surface": css(opaqueOverlayFill(tokens, OPAQUE_OVERLAY_LIFT)),
      "--cmux-tooltip-tint": css(tooltip.tint),
      "--cmux-tooltip-ink": css(tooltip.ink),
      "--cmux-card-tint": css(card.tint),
      "--cmux-card-rim": lines ? css(card.rim) : "transparent",
      "--cmux-scrim": css(scrim(tokens)),
      "--cmux-text": css(tokens.textPrimary),
      "--cmux-text-secondary": css(tokens.textSecondary),
      "--cmux-text-tertiary": css(tokens.textTertiary),
      "--cmux-separator": lines ? css(tokens.separator) : "transparent",
      // The chrome's one divider (Palette.chromeDivider): the sidebar's edge line, the split lines
      // and the tab row's divider. The window sidebar's edge line is the same value (the app's split
      // divider override wins there; the gallery has none).
      "--cmux-chrome-divider": divider,
      "--cmux-sidebar-line": divider,
      // The title area tone: 1 when the chrome is a shade apart from the content (Subtle Tone), and
      // then the folder tab's fill, the content's own surface (Palette.folderTabFill: the page
      // colour in an opaque window, clear over a picture), else clear.
      "--cmux-chrome-tone": toned ? "1" : "0",
      "--cmux-folder-fill": toned ? css(seeThrough ? withAlpha(page, 0) : page) : "transparent",
      // The window sidebar's own fill: the chrome's shade (black at Metrics.mainPaneChromeShade),
      // none under One Color (the sidebar is the window's color, parted by its line); the gallery has
      // no sidebar color.
      "--cmux-sidebar-surface": shade > 0 ? css(withAlpha(BLACK, shade)) : "transparent",
      "--cmux-hover": css(tokens.hoverFill),
      "--cmux-selection": css(tokens.selectionFill),
      // The gallery has no Ghostty cursor color: the text color. Selected text is the app's one
      // highlight (WebTheme.swift), the same token native text fields use.
      "--cmux-text-selection": css(tokens.textSelection),
      "--cmux-caret": css(tokens.textPrimary),
      "--cmux-accent": css(tokens.accent),
      "--cmux-on-accent": css(tokens.onAccent),
      "--cmux-lit-glyph": css(litGlyph(tokens)),
      ...(app ? appThemeVariables(app) : {}),
    },
    colorScheme: tokens.isDark ? "dark" : "light",
    scrollers: "overlay",
    terminal: {
      type: tokens.isDark ? "dark" : "light",
      background: hex(tokens.surfaceBackground),
      foreground: hex(tokens.textPrimary),
      palette: Object.fromEntries(tokens.ansi.slice(0, 16).map((color, index) => [String(index), hex(color)])),
      selectionBackground: hex(tokens.textSelection),
      fontFamily: options.fontFamily ?? null,
    },
    // The gallery shows each change at once: no color fade (a capture must not catch a blend).
    transition: { duration: "0ms", easing: "ease-out", space: "srgb" },
    statusIndicators: options.reducedMotion ? "static" : "animated",
    workingLook: "spinner",
    motion: options.reducedMotion ? "reduced" : "full",
    glass: options.glass ?? "plain",
  };
}

/** The knobs WebTheme.swift reads besides the tokens: `appearance.borders`, Reduce Motion (the web
 * motion policy), the web glass mode (`GlassLensMode`), the terminal's font family and
 * `appearance.titleAreaTone`. */
export type WebThemeOptions = {
  borders?: "lines" | "none";
  titleAreaTone?: TitleAreaToneName;
  reducedMotion?: boolean;
  glass?: "plain" | "lens" | "spectrum";
  fontFamily?: string | null;
};

/** WebTheme(tokens).payload: what `window.cmuxTheme.apply` takes. */
export type WebThemePayload = {
  variables: Record<string, string>;
  colorScheme: "dark" | "light";
  scrollers: "overlay" | "legacy";
  terminal: {
    type: "dark" | "light";
    background: string;
    foreground: string;
    palette: Record<string, string>;
    selectionBackground: string;
    fontFamily: string | null;
  };
  transition: { duration: string; easing: string; space: string };
  statusIndicators: "static" | "animated";
  workingLook: string;
  motion: "full" | "reduced" | "off";
  glass: "plain" | "lens" | "spectrum";
  /** The filled personality slots (ThemeDecorations.swift), sent only while one is filled. */
  decorations?: Record<string, string>;
};

/** The pane's fade durations in seconds (MotionTunables.swift); under Reduce Motion each is at
 * most one crossfade and hover is instant (MotionPolicy.duration). `move` is the move spring's
 * timed equivalent, instant under Reduce Motion. */
const MOTION = { hover: 0.08, hoverOut: 0, focus: 0.1, fadeIn: 0.12, fadeOut: 0.08, move: 0.19 } as const;
const CROSSFADE = 0.1;

/** AgentPaneTheme.values(tokens); `seeThrough` as in webThemePayload (AgentPaneTheme.pageColor),
 * `borders` is `appearance.borders`. */
export function agentPaneTheme(
  tokens: ThemeTokens,
  reducedMotion: boolean,
  seeThrough = false,
  borders: "lines" | "none" = "lines",
): Record<string, unknown> {
  const page = withAlpha(tokens.surfaceBackground, seeThrough ? 0 : 1);
  const opaquePage = withAlpha(tokens.contentBackground, 1);
  const motion = Object.fromEntries(
    Object.entries(MOTION).map(([key, seconds]) => [
      key,
      !reducedMotion ? seconds : key.startsWith("hover") || key === "move" ? 0 : Math.min(seconds, CROSSFADE),
    ]),
  );
  return {
    isDark: tokens.isDark,
    pageBackground: css(page),
    surfaceBackground: css(page),
    surfaceElevatedBackground: css(tokens.elevatedBackground),
    inputBackground: css(tokens.hoverFill),
    border: css(tokens.separator),
    borderStrong: css(tokens.paneBorder),
    borders,
    text: css(tokens.textPrimary),
    mutedText: css(tokens.textSecondary),
    softText: css(tokens.textTertiary),
    accent: css(tokens.accent),
    onAccent: css(tokens.onAccent),
    accentSoft: css(tokens.selectionFill),
    litGlyph: css(litGlyph(tokens)),
    accentText: css(opaquePage),
    danger: css(tokens.danger),
    warning: css(tokens.attention),
    success: css(tokens.success),
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
