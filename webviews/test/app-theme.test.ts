// The app theme (src/theme/appTheme.ts) on every bundled Ghostty theme: each contract pair meets its
// WCAG minimum, the accent hue comes from the theme's own palette, and the tokens stay the theme's
// (a theme whose colors already pass keeps them).
import { describe, expect, test } from "bun:test";
import { readShippedThemes } from "../dev-server/galleryHost";
import {
  ACCENT_MIN_CHROMA,
  APP_THEME_CONTRACT,
  APP_THEME_TOKENS,
  accentSlot,
  appThemeVariables,
  contrastReport,
  deriveAppTheme,
  fit,
} from "../src/theme/appTheme";
import { contrast, hueDistance, parseHex, toOklch } from "../src/theme/color";

const themes = readShippedThemes();

describe("app theme", () => {
  test("covers every bundled theme", () => {
    expect(themes.length).toBeGreaterThanOrEqual(617);
  });

  test("every token pair meets its contrast target on all bundled themes", () => {
    const failures: string[] = [];
    for (const theme of themes) {
      for (const result of contrastReport(deriveAppTheme(theme)))
        if (!result.pass)
          failures.push(`${theme.name}: ${result.token} on ${result.on} ${result.ratio.toFixed(2)} < ${result.min}`);
    }
    expect(failures).toEqual([]);
  });

  test("the contract names every text and UI token, and only real tokens", () => {
    const names = new Set(Object.keys(APP_THEME_TOKENS));
    for (const pair of APP_THEME_CONTRACT) {
      expect(names.has(pair.token)).toBe(true);
      expect(names.has(pair.on)).toBe(true);
      expect(APP_THEME_TOKENS[pair.on].role === "surface" || pair.token === "onAccent").toBe(true);
    }
    const checked = new Set(APP_THEME_CONTRACT.map((pair) => pair.token));
    for (const [name, spec] of Object.entries(APP_THEME_TOKENS))
      if (spec.role === "text" || spec.role === "ui")
        expect({ name, checked: checked.has(name as never) }).toEqual({ name, checked: true });
  });

  test("the default Ghostty palette gives a neutral accent, never the blue ANSI 4 (dark and light)", () => {
    for (const [background, foreground] of [
      ["#282c34", "#ffffff"],
      ["#ffffff", "#1d1f21"],
    ]) {
      const app = deriveAppTheme({ background, foreground, palette: [] });
      for (const token of ["accent", "focusRing", "accentText"] as const) {
        expect({ token, chroma: toOklch(parseHex(app.tokens[token])!).c < 0.02 }).toEqual({ token, chroma: true });
      }
      expect(contrastReport(app).filter((result) => !result.pass)).toEqual([]);
    }
  });

  test("the accent hue comes from the theme's palette, never a fixed hue", () => {
    const wrong: string[] = [];
    for (const theme of themes) {
      const app = deriveAppTheme(theme);
      const accent = toOklch(parseHex(app.tokens.accent)!);
      if (app.accentSource === null) {
        // A palette without color gets a neutral accent.
        if (accent.c > 0.03) wrong.push(`${theme.name}: neutral palette, accent chroma ${accent.c.toFixed(3)}`);
        continue;
      }
      const seed = toOklch(parseHex(theme.palette[app.accentSource]!)!);
      expect(seed.c).toBeGreaterThanOrEqual(ACCENT_MIN_CHROMA);
      // Near white or black the gamut leaves little chroma, and the hue is not visible.
      if (accent.c > 0.03 && hueDistance(accent.h, seed.h) > 6)
        wrong.push(`${theme.name}: accent hue ${accent.h.toFixed(0)} vs slot ${app.accentSource} ${seed.h.toFixed(0)}`);
    }
    expect(wrong).toEqual([]);
  });

  test("a palette whose blue slot has color takes its accent there; others take the most colorful slot", () => {
    const gray = Array.from({ length: 16 }, () => "#808080");
    const rgb = (list: string[]) => list.map((hex) => parseHex(hex)!);
    expect(accentSlot(rgb(gray))).toBeNull();
    const greenOnly = [...gray];
    greenOnly[2] = "#22aa44";
    expect(accentSlot(rgb(greenOnly))).toBe(2);
    const withBlue = [...greenOnly];
    withBlue[4] = "#6b5bd6";
    expect(accentSlot(rgb(withBlue))).toBe(4);
    const app = deriveAppTheme({ background: "#101010", foreground: "#e0e0e0", palette: greenOnly });
    expect(app.accentSource).toBe(2);
    expect(hueDistance(toOklch(parseHex(app.tokens.accent)!).h, toOklch(parseHex("#22aa44")!).h)).toBeLessThan(6);
  });

  test("colors that already pass are kept, and fit changes only lightness", () => {
    expect(fit(parseHex("#ffffff")!, [{ on: parseHex("#000000")!, min: 4.5 }])).toEqual(parseHex("#ffffff")!);
    const moved = fit(parseHex("#3355aa")!, [{ on: parseHex("#1a1a1a")!, min: 4.5 }]);
    expect(contrast(moved, parseHex("#1a1a1a")!)).toBeGreaterThanOrEqual(4.5);
    expect(hueDistance(toOklch(moved).h, toOklch(parseHex("#3355aa")!).h)).toBeLessThan(4);
    const app = deriveAppTheme(themes.find((theme) => theme.name === "Dracula")!);
    expect(app.tokens.window).toBe("#282a36");
    expect(app.tokens.text).toBe("#f8f8f2");
    expect(app.accentSource).toBe(4);
  });

  test("CSS variables cover every token", () => {
    const variables = appThemeVariables(deriveAppTheme(themes[0]!));
    expect(Object.keys(variables).sort()).toEqual(
      Object.values(APP_THEME_TOKENS)
        .map((spec) => spec.variable)
        .sort(),
    );
    for (const value of Object.values(variables)) expect(value).toMatch(/^#[0-9a-f]{6}$/);
  });
});

test("the Swift port's vectors are current (schemas/theme/app-theme-vectors.json)", async () => {
  const { vectors, VECTORS_PATH } = await import("../scripts/theme/export-app-theme-vectors");
  const fs = await import("node:fs");
  expect(fs.readFileSync(VECTORS_PATH, "utf8")).toBe(vectors());
});
