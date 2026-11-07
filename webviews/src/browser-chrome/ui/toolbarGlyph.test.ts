import { describe, expect, test } from "bun:test";
import { bundledIconPack } from "../../agent-session/acpmux/icons/iconPack";
import { inkBounds } from "../../agent-session/acpmux/icons/opticalFit";
import type { IconLayer } from "../../agent-session/acpmux/icons/types";
import { FILLED_LINE_WEIGHT, fitGlyph, glyphRule, OPTICAL_TRIM } from "./toolbarGlyph";

const layers = (name: string) => bundledIconPack.icons[name]!.line as IconLayer[];

/** The drawn glyph in px: its ink box's longer side, its line weight and its center offset. */
function drawn(name: string, box = 20) {
  const scale = glyphRule(20).button;
  const fit = fitGlyph(layers(name), scale, box, OPTICAL_TRIM[name] ?? 1);
  const [x, y, units] = fit.viewBox.split(" ").map(Number);
  const pxPerUnit = box / units;
  const ink = inkBounds(layers(name))!;
  const outline = fit.outline * pxPerUnit;
  return {
    ink: Math.max(ink.x1 - ink.x0, ink.y1 - ink.y0) * pxPerUnit + outline,
    weight: FILLED_LINE_WEIGHT * pxPerUnit + outline,
    dx: ((ink.x0 + ink.x1) / 2 - x) * pxPerUnit - box / 2,
    dy: ((ink.y0 + ink.y1) / 2 - y) * pxPerUnit - box / 2,
  };
}

describe("toolbar glyphs", () => {
  // Leo, 2026-11-07: "Why is the puzzle icon so damn big?" Drawn at one size the puzzle was 16 px of
  // ink a pixel above the line, the arrows 12, the star 14.4.
  test("the arrows, reload, chip, star, puzzle and More share one ink size and line weight", () => {
    const names = [
      "browser.toolbar.back",
      "browser.toolbar.forward",
      "browser.toolbar.reload",
      "browser.omnibox.pageinfo",
      "browser.omnibox.star",
      "browser.toolbar.extensions",
      "action.more.vertical",
    ];
    for (const name of names) {
      const glyph = drawn(name);
      const trim = OPTICAL_TRIM[name] ?? 1;
      expect({ name, ink: glyph.ink / trim }).toEqual({ name, ink: expect.closeTo(12.5, 2) });
      expect({ name, weight: glyph.weight }).toEqual({ name, weight: expect.closeTo(1.5625, 2) });
    }
  });

  test("every glyph centers its ink on its box", () => {
    for (const name of ["browser.toolbar.extensions", "browser.omnibox.star", "browser.toolbar.media"]) {
      const glyph = drawn(name);
      expect(Math.abs(glyph.dx)).toBeLessThan(0.01);
      expect(Math.abs(glyph.dy)).toBeLessThan(0.01);
    }
  });

  test("a glyph drawn small on purpose keeps the weight and stays small", () => {
    const stop = drawn("browser.toolbar.stop");
    expect(stop.weight).toBeCloseTo(1.5625, 2);
    expect(stop.ink).toBeLessThan(12.5);
  });

  test("a line drawing gets the row's weight as its stroke", () => {
    const scale = glyphRule(20).button;
    const fit = fitGlyph(layers("theme"), scale, 20);
    const units = Number(fit.viewBox.split(" ")[2]);
    const stroke = fit.layers.find((layer) => layer.op === "stroke")!;
    expect(fit.outline).toBe(0);
    expect((stroke.w! * 20) / units).toBeCloseTo(1.5625, 2);
  });

  test("the rule scales with the density's icon box", () => {
    expect(glyphRule(22).button.ink).toBeCloseTo(13.75, 5);
    expect(glyphRule(20).badge).toBe(15);
  });
});
