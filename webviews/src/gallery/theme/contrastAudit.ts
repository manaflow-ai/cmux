// The contrast detector's token layer: "light on light / dark on dark" (Leo, 2026-11-19: "you guys also
// need to watch for if there's light on light or dark on dark"). For one subject (a shipped look or a
// shipped theme, in its scheme) it resolves the colors the UI draws, from the same derivation the app
// uses (tokens.ts, overlays.ts, web.ts: ports of CmuxTheme and WebTheme.swift), and checks three
// kinds of pair:
//
//   text   ink on the surface it sits on, WCAG 2 AA: 4.5:1 (3:1 for large text, 24 px or 18.66 px bold)
//   ui     an icon, glyph, status mark or control edge on its surface, WCAG 1.4.11: 3:1
//   blend  a surface beside the surface it is meant to stand apart from (sidebar beside the pane,
//          the active tab on its strip, a card on its page, a menu over its window, the composer in
//          its chat): their OKLCH lightness differs by less than BLEND_MIN_DELTA_L and no drawn
//          line parts them, so the two read as one.
//
// BLEND_MIN_DELTA_L, from known pairs (OKLCH L difference, no line between them unless noted):
//   good  VS Code Dark+ sidebar #252526 | editor #1e1e1e      0.030
//         Linear dark sidebar #090909 | page #0f0f11          0.030
//         Claude Desktop sidebar #f0eee6 | page #faf9f5       0.033
//         Xcode dark navigator #282828 | editor #1f1f24       0.035
//         VS Code Light+ sidebar #f3f3f3 | editor #ffffff     0.036
//         ChatGPT dark sidebar #171717 | main #212121         0.043
//         GitHub light card #f6f8fa | page #ffffff            0.022 (drawn with a 1 px border)
//   bad   #fafafa on #ffffff (a 2% lift: reads as no card)     0.015
//         #1e1e1e beside #202020                              0.009
// Every borderless known-good pair is at 0.0295 or more and every pair that reads as one surface is
// at 0.015 or less; OKLab's just-noticeable difference is about 0.02. 0.025 sits between the two
// groups with margin on both sides: the GitHub card at 0.022 passes only because of its border, as it
// should here.
//
// The surfaces are modelled from the look's own settings (appearance.surfaces.*, sidebarSurface,
// chromeStyle, borders, backgroundOpacity and a background picture, which counts as #808080 as in
// schemas/theme/chrome-layer-colors.json). The rendered layer (test/contrast-rendered-browser.test.ts)
// checks the same thing on the pixels the gallery draws.
import { toOklch } from "../../theme/color";
import type { AppAccent } from "../../theme/appTheme";
import type { GhosttyTheme } from "./ghostty";
import { cardMaterial, OPAQUE_OVERLAY_LIFT, tooltipSurface, worstContrast } from "./overlays";
import {
  BLACK,
  composited,
  contrast,
  hex,
  litGlyph,
  opaqueOverlayFill,
  parseHex,
  rgb,
  wallpaperTintOpacity,
  withAlpha,
  type ThemeRGB,
  type ThemeTokens,
} from "./tokens";
import { themeTokens } from "./web";

export const TEXT_MIN = 4.5;
export const LARGE_TEXT_MIN = 3;
export const UI_MIN = 3;
export const BLEND_MIN_DELTA_L = 0.025;
/** What a background picture counts as under the window's tint (chrome-layer-colors.json). */
export const PICTURE_STAND_IN = rgb(0.5, 0.5, 0.5);

/** The settings of a theme file (Resources/theme-files/*.json) the detector reads. */
export type LookSettings = Record<string, unknown> & {
  name?: string;
  colors?: { background?: string; foreground?: string; selection?: string; accent?: string };
};

export type Subject = {
  /** `look:<file name>` for a theme file, `theme:<Ghostty name>` for a bare theme, `default` for the app. */
  id: string;
  /** The Ghostty theme it draws with, after the look's own colors. */
  theme: GhosttyTheme;
  scheme: "light" | "dark";
  accent: AppAccent;
  look?: LookSettings;
};

export type FindingKind = "text" | "ui" | "blend";

export type Finding = {
  /** Stable across runs: `<subject> <scheme> <kind> <element>`. The baseline keys on it. */
  key: string;
  subject: string;
  theme: string;
  scheme: "light" | "dark";
  kind: FindingKind;
  /** What is drawn on what: `text-secondary on sidebar`, `sidebar beside pane`. */
  element: string;
  foreground: string;
  background: string;
  /** The contrast ratio (text, ui) or the OKLCH lightness difference (blend). */
  value: number;
  minimum: number;
};

const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const num = (value: unknown): number | undefined => (typeof value === "number" ? value : undefined);

/** The theme a look names for `scheme`: `appearance.theme` is one name or `light:A,dark:B`. */
export function lookThemeName(look: LookSettings, scheme: "light" | "dark"): string | undefined {
  const value = str(look["appearance.theme"]);
  if (!value) return undefined;
  if (!value.includes(":")) return value.trim();
  for (const part of value.split(",")) {
    const [side, name] = part.split(":").map((s) => s.trim());
    if (side === scheme && name) return name;
  }
  return undefined;
}

/** The theme with a look's `colors` laid over it (appearance.themeEdits), as ThemeBridge applies them. */
export function editedTheme(theme: GhosttyTheme, look: LookSettings): GhosttyTheme {
  const colors = look.colors ?? {};
  const ok = (value: string | undefined) => (value && parseHex(value) ? hex(parseHex(value)!) : undefined);
  return {
    ...theme,
    background: ok(colors.background) ?? theme.background,
    foreground: ok(colors.foreground) ?? theme.foreground,
    selectionBackground: ok(colors.selection) ?? theme.selectionBackground,
    accent: ok(colors.accent) ?? theme.accent,
  };
}

/** ChromeStyle.separateShade (CmuxNextDesignTokens/ChromeStyle.swift); nil styles take the tunable. */
function separateShade(style: string | undefined, isDark: boolean): number {
  switch (style) {
    case "twoTone":
    case "two-tone":
      return isDark ? 0.12 : 0.02;
    case "floating":
      return isDark ? 0.14 : 0.03;
    case "blocks":
      return isDark ? 0.34 : 0.08;
    default:
      // ChromeTunables.mainPaneShadeDark / Light.
      return isDark ? 0.28 : 0.045;
  }
}

/** The opaque colors each part of the window shows, for one subject. */
export type Surfaces = {
  tokens: ThemeTokens;
  /** The window as it shows behind the panes (its tint over a picture when there is one). */
  window: ThemeRGB;
  pane: ThemeRGB;
  sidebar: ThemeRGB;
  strip: ThemeRGB;
  agentPane: ThemeRGB;
  /** Whether a drawn line parts the sidebar from the pane, and borders in general. */
  sidebarLine: boolean;
  lines: boolean;
  separate: boolean;
};

export function resolveSurfaces(subject: Subject): Surfaces {
  const look = subject.look ?? {};
  const tokens = themeTokens(subject.theme, subject.accent);
  const bg = withAlpha(tokens.windowBackground, 1);
  const picture = (str(look["appearance.background"]) ?? "none") !== "none";
  const opacity = num(look["appearance.backgroundOpacity"]) ?? 1;
  // Over a picture the window is its tint at the wallpaper opacity; else the background at its opacity
  // over the stand-in (an opaque window is just the background).
  const tint = picture ? wallpaperTintOpacity(tokens) : opacity;
  const window = tint >= 1 ? bg : composited(withAlpha(bg, tint), PICTURE_STAND_IN);
  const over = (key: string, base: ThemeRGB): ThemeRGB | null => {
    const color = str(look[`appearance.surfaces.${key}.color`]);
    const alpha = num(look[`appearance.surfaces.${key}.opacity`]);
    if (color === undefined && alpha === undefined) return null;
    const parsed = color ? parseHex(color) : null;
    // SurfaceBackgrounds.fill: a color at its opacity (or the window's); an opacity alone lays the
    // background over the window's tint to cover the backdrop that much.
    if (parsed) return composited(withAlpha(parsed, parsed.alpha * (alpha ?? tint)), window);
    const target = alpha ?? tint;
    if (target <= tint) return base;
    return composited(withAlpha(bg, (target - tint) / (1 - tint)), base);
  };
  const borders = (str(look["appearance.borders"]) ?? "lines") !== "none";
  const separate = str(look["appearance.sidebarSurface"]) === "separate";
  const sidebarBorder = look["sidebar.border"] === true || (num(look["sidebar.borderWidth"]) ?? 0) > 0;
  const shade = separate ? separateShade(str(look["appearance.chromeStyle"]), tokens.isDark) : 0;
  const chrome = shade > 0 ? composited(withAlpha(BLACK, shade), window) : window;
  const pane = over("terminal", window) ?? window;
  return {
    tokens,
    window,
    pane,
    sidebar: over("sidebar", chrome) ?? chrome,
    strip: over("tabBar", chrome) ?? chrome,
    agentPane: over("agentPane", window) ?? window,
    sidebarLine: borders && (sidebarBorder || !separate),
    lines: borders,
    separate,
  };
}

const deltaL = (a: ThemeRGB, b: ThemeRGB) =>
  Math.abs(toOklch({ r: a.red, g: a.green, b: a.blue }).l - toOklch({ r: b.red, g: b.green, b: b.blue }).l);

/** Every finding for one subject. */
export function audit(subject: Subject): Finding[] {
  const s = resolveSurfaces(subject);
  const t = s.tokens;
  const out: Finding[] = [];
  const push = (kind: FindingKind, element: string, fg: ThemeRGB, bg: ThemeRGB, value: number, minimum: number) => {
    if (value >= minimum) return;
    out.push({
      key: `${subject.id} ${subject.scheme} ${kind} ${element}`,
      subject: subject.id,
      theme: subject.theme.name,
      scheme: subject.scheme,
      kind,
      element,
      foreground: hex(fg),
      background: hex(bg),
      value: Math.round(value * 1000) / 1000,
      minimum,
    });
  };
  const ink = (kind: "text" | "ui", name: string, color: ThemeRGB, surfaceName: string, surface: ThemeRGB) => {
    const fg = composited(color, surface);
    push(kind, `${name} on ${surfaceName}`, fg, surface, contrast(fg, surface), kind === "text" ? TEXT_MIN : UI_MIN);
  };
  const popup = withAlpha(opaqueOverlayFill(t, OPAQUE_OVERLAY_LIFT), 1);
  const card = composited(cardMaterial(t).tint, s.pane);
  const composer = composited(t.hoverFill, s.agentPane);
  const sidebarSelected = composited(t.selectionFill, s.sidebar);
  const paneSelected = composited(t.selectionFill, s.pane);
  const paneHover = composited(t.hoverFill, s.pane);
  // The active tab: the folder tab takes the page's own color on a shaded strip, else the selection.
  const activeTab = s.separate && s.strip !== s.pane ? s.pane : composited(t.selectionFill, s.strip);

  const textSurfaces: [string, ThemeRGB][] = [
    ["pane", s.pane],
    ["sidebar", s.sidebar],
    ["tab strip", s.strip],
    ["active tab", activeTab],
    ["agent pane", s.agentPane],
    ["composer", composer],
    ["menu", popup],
    ["card", card],
    ["selected sidebar row", sidebarSelected],
    ["selected row", paneSelected],
    ["hovered row", paneHover],
  ];
  for (const [name, surface] of textSurfaces) {
    ink("text", "text", t.textPrimary, name, surface);
    ink("text", "text-secondary", t.textSecondary, name, surface);
    ink("ui", "icon", t.textTertiary, name, surface);
  }
  for (const [name, surface] of [
    ["pane", s.pane],
    ["sidebar", s.sidebar],
  ] as const) {
    ink("ui", "lit glyph", litGlyph(t), name, surface);
    ink("ui", "accent", t.accent, name, surface);
    ink("ui", "danger", t.danger, name, surface);
    ink("ui", "attention", t.attention, name, surface);
    ink("ui", "success", t.success, name, surface);
  }
  ink("ui", "focus ring", t.focusRing, "pane", s.pane);
  ink("text", "on-accent", t.onAccent, "accent", composited(t.accent, s.pane));
  ink("text", "highlight text", t.highlightText, "highlight", composited(t.highlight, s.pane));
  const tooltip = tooltipSurface(t);
  const tooltipWorst = worstContrast(tooltip.ink, tooltip.tint);
  push("text", "tooltip ink on tooltip", tooltip.ink, composited(tooltip.tint, BLACK), tooltipWorst, TEXT_MIN);

  // Surfaces meant to stand apart. A drawn line parts a pair when the look draws borders.
  const blend = (name: string, a: ThemeRGB, b: ThemeRGB, parted: boolean) => {
    if (parted) return;
    push("blend", name, a, b, deltaL(a, b), BLEND_MIN_DELTA_L);
  };
  if (s.separate) blend("sidebar beside pane", s.sidebar, s.pane, s.sidebarLine);
  blend("active tab on tab strip", activeTab, s.strip, false);
  blend("card on page", card, s.pane, s.lines);
  blend("menu over window", popup, s.window, s.lines);
  blend("composer in chat", composer, s.agentPane, s.lines);
  blend("selected sidebar row in sidebar", sidebarSelected, s.sidebar, false);
  return out;
}

/** The subjects of every theme: each shipped Ghostty theme in its own scheme, neutral accent. */
export function themeSubjects(themes: GhosttyTheme[], isDark: (theme: GhosttyTheme) => boolean): Subject[] {
  return themes.map((theme) => ({
    id: `theme:${theme.name}`,
    theme,
    scheme: isDark(theme) ? ("dark" as const) : ("light" as const),
    accent: "neutral" as const,
  }));
}

/**
 * The subjects of a look, light and dark. A look that names one theme draws that theme on both sides
 * (the app's light/dark flip changes nothing), so it is one subject in that theme's own scheme; one
 * that names a pair is two.
 */
export function lookSubjects(
  id: string,
  look: LookSettings,
  byName: Map<string, GhosttyTheme>,
  isDark: (theme: GhosttyTheme) => boolean,
): { subjects: Subject[]; missing: string[] } {
  const accent = (str(look["appearance.accent"]) ?? "neutral") as AppAccent;
  const subjects: Subject[] = [];
  const missing: string[] = [];
  const seen = new Set<string>();
  for (const side of ["light", "dark"] as const) {
    const name = lookThemeName(look, side);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    const base = byName.get(name);
    if (!base) {
      missing.push(name);
      continue;
    }
    const theme = editedTheme(base, look);
    subjects.push({ id: `look:${id}`, theme, scheme: isDark(theme) ? "dark" : "light", accent, look });
  }
  return { subjects, missing };
}
