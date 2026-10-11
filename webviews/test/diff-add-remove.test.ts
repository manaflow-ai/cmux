// Diff additions and deletions read GitHub-style in every theme: fixed greens and reds for light and
// dark pages, not the terminal palette's green and red (which can be teal, pink or neon). Line fills,
// word highlights, gutter bars and the +N -N counts all derive from these two colors. Code tokens
// still take the palette (syntax-theme.test.ts).
import { beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../src/appearance";
import { pageSyntaxVariable } from "../src/syntax-theme";

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

/** A theme whose green and red are far from GitHub's (Synthwave-like neon). */
function neon(background: string, foreground: string) {
  const palette = ["#000000", "#fe4450", "#72f1b8", "#fede5d", "#03edf9", "#ff7edb", "#03edf9", "#ffffff"];
  return {
    background,
    foreground,
    palette: Object.fromEntries(palette.concat(palette).map((color, slot) => [String(slot), color])),
  };
}

test("additions and deletions keep the fixed light and dark colors in any theme", () => {
  applyDiffViewerAppearance(
    resolveDiffViewerAppearance({
      themes: { light: neon("#fbf7ff", "#262335"), dark: neon("#262335", "#f0eff1") },
    }),
  );
  const style = document.documentElement.style;
  expect(style.getPropertyValue("--cmux-diff-addition-fg-light")).toBe("#257a3e");
  expect(style.getPropertyValue("--cmux-diff-addition-fg-dark")).toBe("#8fd88f");
  expect(style.getPropertyValue("--cmux-diff-deletion-fg-light")).toBe("#b42318");
  expect(style.getPropertyValue("--cmux-diff-deletion-fg-dark")).toBe("#ff8a80");
  // Code still follows the palette: a string is the theme's green.
  expect(style.getPropertyValue(pageSyntaxVariable("dark", "string"))).toBe("#72f1b8");
});
