// Diff Colors (Settings > Diff Viewer, `diff.colors`): additions and deletions follow the terminal
// palette by default (Theme), mix toward the background (Muted), or use fixed GitHub-style greens
// and reds (Standard). Line fills, word highlights, gutter bars and the +N -N counts all derive
// from these two colors. Code tokens follow the palette in every mode (syntax-theme.test.ts).
import { beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance, setDiffChangeColors } from "../src/appearance";
import { contrastBetween } from "../src/syntax-colors";
import { pageSyntaxVariable } from "../src/syntax-theme";
import { sanitizeViewerPrefs } from "../src/viewer-prefs";

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

/** A theme whose green and red are far from GitHub's (Synthwave-like neon). */
function neon(background: string, foreground: string) {
  const palette = ["#000000", "#ff6b7a", "#72f1b8", "#fede5d", "#03edf9", "#ff7edb", "#03edf9", "#ffffff"];
  return {
    background,
    foreground,
    palette: Object.fromEntries(palette.concat(palette).map((color, slot) => [String(slot), color])),
  };
}

const appearance = resolveDiffViewerAppearance({
  themes: { light: neon("#fbf7ff", "#262335"), dark: neon("#262335", "#f0eff1") },
});

function variable(name: string): string {
  return document.documentElement.style.getPropertyValue(name);
}

/** HSL saturation, 0 to 1. */
function saturation(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const lightness = (max + min) / 2;
  return max === min ? 0 : (max - min) / (1 - Math.abs(2 * lightness - 1));
}

test("Theme, the default, takes additions and deletions from the palette", () => {
  applyDiffViewerAppearance(appearance);
  expect(variable("--cmux-diff-addition-fg-dark")).toBe("#72f1b8");
  expect(variable("--cmux-diff-deletion-fg-dark")).toBe("#ff6b7a");
});

test("Standard keeps the fixed light and dark colors in any theme", () => {
  // Picking a mode recolors the page already showing a diff.
  setDiffChangeColors("standard");
  expect(variable("--cmux-diff-addition-fg-light")).toBe("#257a3e");
  expect(variable("--cmux-diff-addition-fg-dark")).toBe("#8fd88f");
  expect(variable("--cmux-diff-deletion-fg-light")).toBe("#b42318");
  expect(variable("--cmux-diff-deletion-fg-dark")).toBe("#ff8a80");
  // Code still follows the palette: a string is the theme's green.
  expect(variable(pageSyntaxVariable("dark", "string"))).toBe("#72f1b8");
});

test("Muted keeps the theme's hues, less saturated and still readable", () => {
  const names = ["addition", "deletion"].flatMap((kind) =>
    (["light", "dark"] as const).map((type) => [`--cmux-diff-${kind}-fg-${type}`, type] as const),
  );
  setDiffChangeColors("theme");
  const themed = new Map(names.map(([name]) => [name, variable(name)]));
  setDiffChangeColors("muted");
  for (const [name, type] of names) {
    const muted = variable(name);
    expect(muted).toMatch(/^#[0-9a-f]{6}$/);
    expect(saturation(muted)).toBeLessThan(saturation(themed.get(name) ?? ""));
    const background = type === "light" ? "#fbf7ff" : "#262335";
    expect(contrastBetween(muted, background) ?? 0).toBeGreaterThanOrEqual(4.5);
  }
  expect(variable(pageSyntaxVariable("dark", "string"))).toBe("#72f1b8");
  setDiffChangeColors(undefined);
  expect(variable("--cmux-diff-addition-fg-dark")).toBe("#72f1b8");
});

test("the diff prefs keep a known Diff Colors choice and drop others", () => {
  expect(sanitizeViewerPrefs({ colors: "muted" }).colors).toBe("muted");
  expect(sanitizeViewerPrefs({ colors: "neon" }).colors).toBeUndefined();
});
