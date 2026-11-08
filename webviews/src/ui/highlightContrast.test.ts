// HIGHLIGHT-CONTRAST: a selection or Find match starts from its theme color and keeps it where it
// reads; on a surface where it does not (a chat bubble), its lightness moves until fill and text pass
// (Leo 2026-11-07: "sometimes there's, like, low contrast on the highlight ... in relation to, say,
// some of the bubbles").
import { describe, expect, test } from "bun:test";
import { contrast, parseHex, toOklch, type RGB } from "../theme/color";
import { fitHighlight, fitHighlightOn, HIGHLIGHT_FLOORS, over, webKitSelectionColor } from "./highlightContrast";
import type { RGBA } from "../backdrop";

const hex = (text: string): RGB => parseHex(text)!;
const rgba = (text: string, a = 1): RGBA => {
  const { r, g, b } = hex(text);
  return { r: r * 255, g: g * 255, b: b * 255, a };
};

// A light theme's page and the 5% text tint a prompt's bubble lays over it (conversation.css --cv-bubble).
const page = hex("#ffffff");
const ink = hex("#1d1d1f");
const bubble = over({ ...rgba("#1d1d1f"), a: 0.05 }, page);
// A dark theme's.
const darkPage = hex("#1e1f1c");
const darkInk = hex("#e8e6e3");
const darkBubble = over({ ...rgba("#e8e6e3"), a: 0.05 }, darkPage);

describe("fitHighlight", () => {
  test("a pale selection on a bubble moves until it stands out and its text still reads", () => {
    // A theme's selection color barely off the bubble: the screenshot's case.
    const base = rgba("#e9e9ec");
    expect(contrast(over(base, bubble), bubble)).toBeLessThan(HIGHLIGHT_FLOORS.selection.surface);
    const fit = fitHighlight(base, bubble, ink, HIGHLIGHT_FLOORS.selection);
    expect(contrast(fit.fill, bubble)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.surface);
    expect(contrast(fit.ink, fit.fill)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.ink);
    expect(fit.ink).toEqual(ink);
  });

  test("a selection that already reads keeps its color", () => {
    const base = rgba("#b3d7ff");
    const fit = fitHighlight(base, page, ink, HIGHLIGHT_FLOORS.selection);
    expect(fit.fill).toEqual(over(base, page));
  });

  test("the fit keeps the theme color's hue, only its lightness moves", () => {
    const base = rgba("#e2e8f2");
    const fit = fitHighlight(base, bubble, ink, HIGHLIGHT_FLOORS.selection);
    const before = toOklch(over(base, bubble));
    const after = toOklch(fit.fill);
    expect(Math.abs(after.h - before.h)).toBeLessThan(2);
    expect(after.l).toBeLessThan(before.l);
  });

  test("on a dark bubble a dim selection lightens", () => {
    const base = rgba("#2a2b28");
    const fit = fitHighlight(base, darkBubble, darkInk, HIGHLIGHT_FLOORS.selection);
    expect(contrast(fit.fill, darkBubble)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.surface);
    expect(contrast(darkInk, fit.fill)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.ink);
    expect(toOklch(fit.fill).l).toBeGreaterThan(toOklch(over(base, darkBubble)).l);
  });

  test("Find's current match reaches 3:1 from its surface in both themes, with readable text", () => {
    const yellow = rgba("#f5c542");
    for (const [surface, text] of [
      [page, hex("#1d1d1f")],
      [bubble, hex("#1d1d1f")],
      [darkPage, hex("#1d1d1f")],
      [darkBubble, hex("#1d1d1f")],
    ] as const) {
      const fit = fitHighlight(yellow, surface, text, HIGHLIGHT_FLOORS.findCurrent, { freeInk: true });
      expect(contrast(fit.fill, surface)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.findCurrent.surface);
      expect(contrast(fit.ink, fit.fill)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.findCurrent.ink);
    }
  });

  test("the current match stands apart from the other matches", () => {
    const current = fitHighlight(rgba("#f5c542"), bubble, ink, HIGHLIGHT_FLOORS.findCurrent, { freeInk: true });
    const other = fitHighlight({ ...rgba("#f5c542"), a: 0.4 }, bubble, ink, HIGHLIGHT_FLOORS.findMatch);
    expect(contrast(current.fill, other.fill)).toBeGreaterThanOrEqual(1.5);
  });

  test("muted text keeps what the fill's step leaves it instead of failing the fit", () => {
    const muted = hex("#8a8a8e");
    const fit = fitHighlight(rgba("#f0f0f2"), page, muted, HIGHLIGHT_FLOORS.selection);
    expect(contrast(fit.fill, page)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.surface);
    expect(contrast(muted, fit.fill)).toBeGreaterThanOrEqual(
      contrast(muted, page) / HIGHLIGHT_FLOORS.selection.surface - 0.05,
    );
  });
});

describe("fitHighlightOn", () => {
  test("a selection from a bubble onto the page reads on both", () => {
    const fit = fitHighlightOn(rgba("#e9e9ec"), [bubble, page], ink, HIGHLIGHT_FLOORS.selection);
    for (const surface of [bubble, page])
      expect(contrast(fit.fill, surface)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.surface - 0.01);
  });
});

describe("webKitSelectionColor", () => {
  test("an opaque color becomes the translucent one WebKit paints, which over white looks the same", () => {
    const base = rgba("#abd8ff");
    const painted = webKitSelectionColor(base);
    expect(painted.a).toBeLessThan(1);
    const shown = over(painted, hex("#ffffff"));
    const expected = hex("#abd8ff");
    for (const channel of ["r", "g", "b"] as const)
      expect(Math.abs(shown[channel] - expected[channel])).toBeLessThan(0.01);
  });
});

describe("fitHighlight on muted text", () => {
  // The gallery's tool card: a 40% find tint under gray text on a 4% card went to solid black.
  test("a match under muted text on a card never turns into a dark slab", () => {
    const card = over({ ...rgba("#1d1d1f"), a: 0.04 }, page);
    const muted = hex("#6e6e73");
    const fit = fitHighlight({ ...rgba("#0a84ff"), a: 0.4 }, card, muted, HIGHLIGHT_FLOORS.findMatch);
    expect(contrast(fit.fill, card)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.findMatch.surface);
    expect(contrast(muted, fit.fill)).toBeGreaterThanOrEqual(2.5);
    expect(toOklch(fit.fill).l).toBeGreaterThan(0.6);
  });
});

describe("fitHighlightOn across surfaces", () => {
  // Review F3: fit only to the worst surface, the fill lost contrast on the other one.
  test("the fill keeps the floor on every surface the selection touches", () => {
    const gray = hex("#cccccc");
    const fit = fitHighlightOn(rgba("#e9e9ec"), [page, gray], ink, HIGHLIGHT_FLOORS.selection);
    for (const surface of [page, gray])
      expect(contrast(fit.fill, surface)).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.selection.surface);
  });
});

describe("Find's current match keeps its own text AA", () => {
  // next-review F1 at e03f60d5: on a mid-gray surface the relaxed floor let the fill go dark amber
  // under dark text (1.25:1). Its text color is the highlight's own, so it must stay 4.5:1.
  test("on a mid-gray surface the current match's text stays AA", () => {
    const fit = fitHighlight(rgba("#f5c542"), hex("#777777"), hex("#1d1d1f"), HIGHLIGHT_FLOORS.findCurrent, {
      freeInk: true,
    });
    expect(contrast(fit.ink, fit.fill)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(fit.fill, hex("#777777"))).toBeGreaterThanOrEqual(HIGHLIGHT_FLOORS.findCurrent.surface);
  });

  test("dark text on a light gray surface keeps AA too", () => {
    const fit = fitHighlight(rgba("#e8821e"), hex("#cccccc"), hex("#1a1208"), HIGHLIGHT_FLOORS.findCurrent, {
      freeInk: true,
    });
    expect(contrast(fit.ink, fit.fill)).toBeGreaterThanOrEqual(4.5);
  });
});
