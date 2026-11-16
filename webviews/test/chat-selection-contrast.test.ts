// Selected text stands out on every chat surface, in every bundled theme, in an opaque window and a
// see-through one (user 2026-11-15, Monokai Classic at Opacity 0.85 over a picture: "im highlighting
// text and it is not easily visible"; the selection in their prompt's bubble was #57584f, the theme's
// own selection color, on a bubble that showed as #5a5a54: 1.02:1).
//
// The cause: the selection fit (ui/adaptiveSelection.ts, HIGHLIGHT-CONTRAST) measured each surface
// over the page's root, and under a see-through page that root is clear; it took black (a dark page)
// as what lies under it, where the window really lays its tint over the picture or the desktop. So
// the bubble it measured was far darker than the one on screen, and the theme color "passed".
//
// This drives the real `updateSelectionFill` on a page built the way the app sends it (WebTheme's
// variables from the same token derivation, gallery/theme/web.ts; the bubble's, code's and text's
// fills as conversation.css mixes them) for all 600+ bundled Ghostty themes, opaque and at two
// window opacities, and checks the fill it sets against what the eye sees: each surface over the
// window tint over a black, a mid-gray and a white desktop. Every one must keep the selection floor
// (HIGHLIGHT_FLOORS.selection: the fill plainly off its surface) with its text still readable.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import { themeInput } from "../src/gallery/theme/web";
import {
  css,
  deriveTokens,
  wallpaperTintOpacity,
  withAlpha,
  type ThemeRGB,
  type ThemeTokens,
} from "../src/gallery/theme/tokens";
import { SELECTION_FILL_PROPERTY, updateSelectionFill } from "../src/ui/adaptiveSelection";
import { HIGHLIGHT_FLOORS, over } from "../src/ui/highlightContrast";
import { parseComputedColor } from "../src/backdrop";
import { contrast, BLACK, WHITE, type RGB } from "../src/theme/color";

const THEMES = path.resolve(import.meta.dir, "../../Resources/ghostty/themes");
const FLOOR = HIGHLIGHT_FLOORS.selection;
/** The fit steps lightness by 0.01 and the fill is rounded to 8 bits: a hair of slack. */
const EPSILON = 0.01;
/** The fit's own allowance for text already fainter than AA on its surface (highlightContrast.ts). */
const INK_SLACK = 1.15;

const themes = fs
  .readdirSync(THEMES)
  .sort()
  .map((name) => parseGhosttyTheme(name, fs.readFileSync(path.join(THEMES, name), "utf8")))
  .filter((theme) => theme !== null);

const rgbOf = (color: ThemeRGB): RGB => ({ r: color.red, g: color.green, b: color.blue });
const rgbaOf = (color: ThemeRGB) => ({ r: color.red * 255, g: color.green * 255, b: color.blue * 255, a: color.alpha });

/** The chat surfaces selected text sits on, as conversation.css mixes them from the pane's text. */
const SURFACES = {
  "assistant text": 0,
  "user bubble": 0.14, // .acpmux-shell .cv-user__bubble --glass-tint
  "inline code": 0.11, // --cv-code-bg
  "code block": 0.075, // --cv-codeblock-bg
} as const;

/** `var(--name, fallback)` resolved against `variables`, as the engine does; JSDOM leaves it as is. */
function resolveVars(expression: string, variables: Record<string, string>): string {
  let text = expression;
  for (let guard = 0; guard < 8 && text.includes("var("); guard += 1)
    text = text.replace(
      /var\(\s*(--[\w-]+)\s*(?:,\s*((?:[^()]|\([^()]*\))*))?\)/g,
      (_all, name: string, fallback?: string) => (name in variables ? variables[name]! : (fallback ?? "").trim()),
    );
  return text;
}

type Page = { dom: JSDOM; variables: Record<string, string> };

/** One page for the run: the transcript's surfaces, each holding a line of text. The engine's color
 * probe (resolveCssColor) reads its `color` through the theme's variables. */
function makePage(): Page {
  const rows = Object.keys(SURFACES)
    .map((name) => `<div data-row-id="${name}"><p data-surface="${name}">The quick brown fox jumps over it</p></div>`)
    .join("");
  const dom = new JSDOM(`<!doctype html><html><body>${rows}</body></html>`, { pretendToBeVisual: true });
  const page: Page = { dom, variables: {} };
  const view = dom.window;
  const original = view.getComputedStyle.bind(view);
  view.getComputedStyle = ((element: Element, pseudo?: string | null) => {
    const style = original(element, pseudo);
    if (!element.hasAttribute?.("data-cmux-color-probe")) return style;
    const color = resolveVars((element as HTMLElement).style.color, page.variables);
    return new Proxy(style, { get: (target, key) => (key === "color" ? color : Reflect.get(target, key)) });
  }) as typeof view.getComputedStyle;
  return page;
}

/** A window of `opacity`, over a background picture or not (`picture`). */
type Window = { opacity: number; picture?: boolean };

/** The alpha of the theme tint the window lays over the picture or the desktop (WindowBackdrop.swift):
 * the Opacity asked for, or at full Opacity over a picture the theme's own lighter picture tint
 * (ThemeTokens.wallpaperTintOpacity). */
const tintOf = (tokens: ThemeTokens, { opacity, picture }: Window) =>
  opacity < 1 ? opacity : picture ? wallpaperTintOpacity(tokens) : 1;

/** Paints `page` as the app does for `tokens` in a window of `opacity`: WebTheme's variables, the
 * page background (clear over a see-through window, which then lays its tint natively) and the
 * surfaces' fills. */
function paint(page: Page, tokens: ThemeTokens, window: Window): void {
  const doc = page.dom.window.document;
  const root = doc.documentElement;
  const { opacity } = window;
  const seeThrough = opacity < 1 || window.picture === true;
  const surface = withAlpha(tokens.surfaceBackground, 1);
  const tint = withAlpha(tokens.windowBackground, tintOf(tokens, window));
  page.variables = {
    "--cmux-text-selection": css(tokens.textSelection),
    "--cmux-surface-token": css(withAlpha(tokens.surfaceBackground, opacity)),
    "--cmux-surface-background": css(withAlpha(surface, seeThrough ? 0 : 1)),
    "--cmux-window-tint": css(tint),
  };
  for (const [name, value] of Object.entries(page.variables)) root.style.setProperty(name, value);
  root.style.colorScheme = tokens.isDark ? "dark" : "light";
  root.style.backgroundColor = css(withAlpha(surface, seeThrough ? 0 : 1));
  root.toggleAttribute("data-cmux-see-through", seeThrough);
  for (const [name, share] of Object.entries(SURFACES)) {
    const element = doc.querySelector<HTMLElement>(`[data-surface="${name}"]`)!;
    element.style.color = css(tokens.textPrimary);
    element.style.backgroundColor = share ? css(withAlpha(tokens.textPrimary, share)) : "transparent";
  }
}

/** What the eye sees under the page: the opaque page, or the window's tint over each desktop. */
function canvases(tokens: ThemeTokens, window: Window): RGB[] {
  if (window.opacity >= 1 && !window.picture) return [rgbOf(withAlpha(tokens.surfaceBackground, 1))];
  const tint = rgbaOf(withAlpha(tokens.windowBackground, tintOf(tokens, window)));
  return [BLACK, { r: 0.5, g: 0.5, b: 0.5 }, WHITE].map((desktop) => over(tint, desktop));
}

/** Selects the text of one surface and returns the fill the page set for it. */
function fillFor(page: Page, name: string): RGB | null {
  const doc = page.dom.window.document;
  const text = doc.querySelector(`[data-surface="${name}"]`)!.firstChild!;
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  const range = doc.createRange();
  range.setStart(text, 4);
  range.setEnd(text, 19);
  selection.addRange(range);
  updateSelectionFill(doc);
  const value = doc.documentElement.style.getPropertyValue(SELECTION_FILL_PROPERTY);
  const parsed = value
    ? parseComputedColor(value.replace(/^rgb\((\S+) (\S+) (\S+) \/ (\S+)\)$/, "rgba($1, $2, $3, $4)"))
    : null;
  return parsed ? { r: parsed.r / 255, g: parsed.g / 255, b: parsed.b / 255 } : null;
}

type Miss = {
  theme: string;
  window: string;
  surface: string;
  desktop: number;
  fill: string;
  surfaceRatio: number;
  inkRatio: number;
};

function misses(window: Window): Miss[] {
  const page = makePage();
  const found: Miss[] = [];
  const hex = (color: RGB) =>
    `#${[color.r, color.g, color.b]
      .map((value) =>
        Math.round(value * 255)
          .toString(16)
          .padStart(2, "0"),
      )
      .join("")}`;
  try {
    for (const theme of themes) {
      const tokens = deriveTokens({ ...themeInput(theme), backgroundOpacity: window.opacity });
      paint(page, tokens, window);
      const text = rgbOf(withAlpha(tokens.textPrimary, 1));
      for (const [name, share] of Object.entries(SURFACES)) {
        const fill = fillFor(page, name);
        const surfaces = canvases(tokens, window).map((canvas) =>
          share ? over(rgbaOf(withAlpha(tokens.textPrimary, share)), canvas) : canvas,
        );
        // The fill is one opaque color, so its text reads the same over every desktop: it keeps AA,
        // or what the text has where it reads worst (on the lightest or darkest desktop).
        const inkFloor = Math.min(
          FLOOR.ink,
          Math.min(...surfaces.map((surface) => contrast(text, surface))) / (FLOOR.surface * INK_SLACK),
        );
        surfaces.forEach((surface, desktop) => {
          const shown = fill ?? surface;
          const surfaceRatio = contrast(shown, surface);
          const inkRatio = contrast(text, shown);
          if (surfaceRatio < FLOOR.surface - EPSILON || inkRatio < inkFloor - EPSILON)
            found.push({
              theme: theme.name,
              window: `opacity ${window.opacity}${window.picture ? " over a picture" : ""}`,
              surface: name,
              desktop,
              fill: hex(shown),
              surfaceRatio: Math.round(surfaceRatio * 100) / 100,
              inkRatio: Math.round(inkRatio * 100) / 100,
            });
        });
      }
    }
  } finally {
    page.dom.window.close();
  }
  return found;
}

describe("chat selection contrast", () => {
  test("bundled themes load", () => {
    expect(themes.length).toBeGreaterThan(600);
    expect(themes.some((theme) => theme.name === "Monokai Classic")).toBe(true);
  });

  test("the user's case: Monokai Classic at Opacity 0.85, selection in the prompt bubble", () => {
    const theme = themes.find((one) => one.name === "Monokai Classic")!;
    const window = { opacity: 0.85 };
    const tokens = deriveTokens({ ...themeInput(theme), backgroundOpacity: window.opacity });
    const page = makePage();
    try {
      paint(page, tokens, window);
      const fill = fillFor(page, "user bubble")!;
      expect(fill).not.toBeNull();
      // The bubble as it showed on their screen (CleanShot 2026-11-15 8.08.35 PM), and at both ends
      // of what any desktop can make it.
      const seen: RGB = { r: 0x5a / 255, g: 0x5a / 255, b: 0x54 / 255 };
      expect(contrast(fill, seen)).toBeGreaterThanOrEqual(FLOOR.surface);
      for (const canvas of canvases(tokens, window)) {
        const bubble = over(rgbaOf(withAlpha(tokens.textPrimary, SURFACES["user bubble"])), canvas);
        expect(contrast(fill, bubble)).toBeGreaterThanOrEqual(FLOOR.surface - EPSILON);
      }
    } finally {
      page.dom.window.close();
    }
  });

  // The same setup on a real screen over the user's background picture (laurence-mckinley, a light
  // mountain; a whole-host fleet capture, 2026-11-15): the bubble showed as #535753 and the theme's
  // selection on it as #56574f, 1.02:1, as in the user's screenshot. The fill must stand off that
  // bubble too, with the prompt's text readable on it.
  test("the user's case on a real screen over their picture: the selection stands off the bubble", () => {
    const theme = themes.find((one) => one.name === "Monokai Classic")!;
    const window = { opacity: 0.85, picture: true };
    const tokens = deriveTokens({ ...themeInput(theme), backgroundOpacity: window.opacity });
    const page = makePage();
    try {
      paint(page, tokens, window);
      const fill = fillFor(page, "user bubble")!;
      expect(fill).not.toBeNull();
      const seen: RGB = { r: 0x53 / 255, g: 0x57 / 255, b: 0x53 / 255 };
      expect(contrast(fill, seen)).toBeGreaterThanOrEqual(FLOOR.surface);
      expect(contrast(rgbOf(withAlpha(tokens.textPrimary, 1)), fill)).toBeGreaterThanOrEqual(FLOOR.ink);
    } finally {
      page.dom.window.close();
    }
  });

  for (const window of [{ opacity: 1 }, { opacity: 0.85 }, { opacity: 0.7 }, { opacity: 1, picture: true }])
    test(`every theme, every surface, window opacity ${window.opacity}${window.picture ? " over a picture" : ""}`, () => {
      const found = misses(window);
      if (found.length) console.log(JSON.stringify(found.slice(0, 20), null, 1), `\n${found.length} misses`);
      expect(found).toEqual([]);
    });
});
