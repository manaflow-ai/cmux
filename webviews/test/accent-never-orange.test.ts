// The theme accent is never orange (standing rule). The default theme's accent tokens, in light and
// dark, must fall outside the orange hue band: the app theme the pages get as `--cmux-app-*`
// (src/theme/appTheme.ts, the contract the Swift AppTheme replays through
// schemas/theme/app-theme-vectors.json) and the chrome tokens WebTheme sends as `--cmux-*`
// (src/gallery/theme/tokens.ts, the line-for-line mirror of the Swift ThemeTokens).
//
// The default theme is read from its sources, not restated here: the default pair (Apple System
// Colors, appearance.ts and GhosttyRuntime.defaultThemeSpec) from the shipped Ghostty theme files,
// and the default accent from schemas/defaults/cmux-next.json (`setting.appearance.accent`).
// The Swift side of the same rule is CmuxNextDesignTests/AccentNeverOrangeTests.swift.
//
// Exempt: workspace and tab group palette colors, the status colors (danger red, warning amber),
// and themes or accents a person picks by name (Clay Orange, `appearance.accent: yellow`). Only the
// default theme with the default accent is held to this.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { readShippedThemes } from "../dev-server/galleryHost";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME } from "../src/gallery/theme/ghostty";
import { css, type ThemeRGB } from "../src/gallery/theme/tokens";
import { themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { APP_ACCENTS, deriveAppTheme, type AppAccent, type AppTokenName } from "../src/theme/appTheme";

const REPO = path.resolve(import.meta.dir, "../..");

/**
 * Orange, as a hue band: HSL hue 10° to 45° inclusive, for a color with an RGB chroma
 * (max - min channel) of at least 0.10.
 *
 * - Lower bound 10°: Apple's reds sit near 3° (systemRed #ff3b30 3.2°, dark #ff453a 3.4°, the default
 *   pair's ANSI red #cc372e 3.4°), Ghostty's #cc6666 at 0°, while the orange of a named theme starts
 *   at 14° (Clay Orange's accent #d87657 14.4°) and #e8743b is 20°.
 * - Upper bound 45°: systemOrange is 35° (dark #ff9f0a 36.5°); yellows start at 48° (systemYellow
 *   #ffcc00 48°, dark #ffd60a 50.4°, the default pair's ANSI yellows #cdac08 and #e5bc00 near 50°).
 * - Chroma floor 0.10: below it the color reads as a grey (the neutral default accent is the text
 *   color) and its hue is rounding noise, so it is never orange.
 */
export const ORANGE_HUE = { min: 10, max: 45 } as const;
export const MIN_HUED_CHROMA = 0.1;

/** The HSL hue (0..360) and RGB chroma (0..1) of an sRGB color with channels in 0..1. */
export function hueAndChroma(red: number, green: number, blue: number): { hue: number; chroma: number } {
  const max = Math.max(red, green, blue);
  const min = Math.min(red, green, blue);
  const chroma = max - min;
  if (chroma === 0) return { hue: 0, chroma };
  const sector =
    max === red
      ? ((green - blue) / chroma + 6) % 6
      : max === green
        ? (blue - red) / chroma + 2
        : (red - green) / chroma + 4;
  return { hue: sector * 60, chroma };
}

/** Whether a color is orange (see ORANGE_HUE); alpha is ignored, the hue is the color's own. */
export function isOrange(red: number, green: number, blue: number): boolean {
  const { hue, chroma } = hueAndChroma(red, green, blue);
  return chroma >= MIN_HUED_CHROMA && hue >= ORANGE_HUE.min && hue <= ORANGE_HUE.max;
}

/** `#rrggbb` or `rgb(a)(r, g, b, ...)` as 0..1 channels. */
function channels(color: string): [number, number, number] {
  const hex = /^#([0-9a-f]{6})$/i.exec(color.trim());
  if (hex) {
    const value = parseInt(hex[1]!, 16);
    return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map((v) => v / 255) as [number, number, number];
  }
  const rgb = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i.exec(color.trim());
  if (rgb) return [rgb[1], rgb[2], rgb[3]].map((v) => Number(v) / 255) as [number, number, number];
  throw new Error(`not a color: ${color}`);
}

const orange = (color: string) => isOrange(...channels(color));
const tokenOrange = (color: ThemeRGB) => isOrange(color.red, color.green, color.blue);

/** The default accent, from the generated defaults (the settings registry's fallback). */
function defaultAccent(): AppAccent {
  const defaults = JSON.parse(fs.readFileSync(path.join(REPO, "schemas/defaults/cmux-next.json"), "utf8")) as Record<
    string,
    unknown
  >;
  const accent = defaults["setting.appearance.accent"];
  if (!APP_ACCENTS.includes(accent as AppAccent)) throw new Error(`unknown default accent ${String(accent)}`);
  return accent as AppAccent;
}

const themes = readShippedThemes();
const defaultPair = [DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME].map((name) => {
  const theme = themes.find((candidate) => candidate.name === name);
  if (!theme) throw new Error(`the default theme ${name} is not shipped`);
  return theme;
});

/** Every accent token of the app theme (`--cmux-app-*`). */
const APP_ACCENT_TOKENS: AppTokenName[] = ["accent", "accentText", "focusRing", "selection"];
/** Every accent-carrying chrome token (ThemeTokens; `--cmux-accent`, `--cmux-selection`, the agent
 * pane's highlight) and the page variables WebTheme sends for them. */
const CHROME_ACCENT_TOKENS = [
  "accent",
  "focusRing",
  "selectionFill",
  "secondarySelectionFill",
  "highlight",
  "textSelection",
] as const;
const PAGE_ACCENT_VARIABLES = [
  "--cmux-accent",
  "--cmux-selection",
  "--cmux-app-accent",
  "--cmux-app-accent-text",
  "--cmux-app-focus-ring",
  "--cmux-app-selection",
];

describe("the orange band", () => {
  test("holds the oranges and leaves out reds, yellows, blues and greys", () => {
    // Oranges, the named theme's included (exempt as a pick, but it is orange).
    for (const color of ["#e8743b", "#ff9500", "#ff9f0a", "#d87657", "#f28c28"])
      expect([color, orange(color)]).toEqual([color, true]);
    // The default pair's reds and yellows, Apple's blue, and greys (the neutral accent).
    for (const color of [
      "#ff3b30",
      "#ff453a",
      "#cc372e",
      "#ffcc00",
      "#ffd60a",
      "#cdac08",
      "#e5bc00",
      "#0a84ff",
      "#ffffff",
      "#000000",
      "#fcfcfc",
      "#8a8580",
    ])
      expect([color, orange(color)]).toEqual([color, false]);
  });
});

describe("the default theme's accent is never orange", () => {
  const accent = defaultAccent();

  for (const theme of defaultPair) {
    test(`${theme.name} (${accent}): the app theme's accent tokens`, () => {
      const app = deriveAppTheme(theme, accent);
      const hits = APP_ACCENT_TOKENS.filter((token) => orange(app.tokens[token])).map(
        (token) => `${token} ${app.tokens[token]}`,
      );
      expect(hits).toEqual([]);
    });

    test(`${theme.name} (${accent}): the chrome accent tokens and the page variables`, () => {
      const tokens = themeTokens(theme, accent);
      const chromeHits = CHROME_ACCENT_TOKENS.filter((token) => tokenOrange(tokens[token])).map(
        (token) => `${token} ${css(tokens[token])}`,
      );
      expect(chromeHits).toEqual([]);
      const variables = webThemePayload(tokens, deriveAppTheme(theme, accent)).variables;
      const pageHits = PAGE_ACCENT_VARIABLES.filter((name) => {
        const value = variables[name];
        if (value === undefined) throw new Error(`WebTheme sends no ${name}`);
        return orange(value);
      }).map((name) => `${name} ${variables[name]}`);
      expect(pageHits).toEqual([]);
    });
  }

  // The Swift AppTheme must equal these vectors (its tests replay them), so the native accent of
  // the default pair is held by the same check.
  test("the vectors the Swift port replays carry no orange accent for the default pair", () => {
    const vectors = JSON.parse(fs.readFileSync(path.join(REPO, "schemas/theme/app-theme-vectors.json"), "utf8")) as {
      cases: { name: string; accent?: string; tokens: Record<string, string> }[];
    };
    const cases = vectors.cases.filter(
      (item) => [DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME].includes(item.name) && (item.accent ?? "neutral") === accent,
    );
    expect(cases.length).toBeGreaterThanOrEqual(2);
    const hits = cases.flatMap((item) =>
      APP_ACCENT_TOKENS.filter((token) => orange(item.tokens[token]!)).map(
        (token) => `${item.name} ${token} ${item.tokens[token]}`,
      ),
    );
    expect(hits).toEqual([]);
  });
});
