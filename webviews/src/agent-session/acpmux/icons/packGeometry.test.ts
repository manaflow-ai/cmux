import { describe, expect, test } from "bun:test";
import catalog from "../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextIcons/Resources/icon-catalog.json";
import bundled from "./cmuxIcons.json";
import { inkBounds } from "./opticalFit";
import type { IconPack } from "./types";

const pack = bundled as IconPack;

// design/icons/SPEC.md "Centering and optical size": every glyph's ink box sits on 12,12 within 0.5
// units. The rule was checked only by the hand-run tools in design/icons/tools, which read a folder
// the sources had moved out of, so a drawing edited since was never measured (Leo, 2026-11-07: "the
// icons all look good and as if they were from the same family and the same sizing and the same,
// like, ratios and justifications"). This test runs the geometric half of those checks on every push.
const CENTER_TOLERANCE = 0.5;

// Named exceptions, each with its reason. Chromium's vendored glyphs keep Chrome's own placement.
const OFF_CENTER: Record<string, string> = {
  "action.resume": "SPEC: a play triangle sits right of its box",
  "media.play": "SPEC: a play triangle sits right of its box",
  "disclosure.collapsed": "SPEC: the collapsed chevron sits 1 right",
  "terminal.new": "optical.py V_TOLERANCE: a bottom-right plus badge may sit a little low",
  "status.progress": "drawn before this check: 0.504 left, at the rasteriser's rounding edge",
};

// design/icons/SPEC.md "Line style": every Line drawing strokes at 1.5 on the 24 grid. A 16-unit glyph pasted in
// under a scale(1.5) wrapper at 1.25 drew 1.875, a quarter heavier than its neighbours (the transcript and
// permission-mode batches until 2026-11-22), and a matrix() optical trim thinned task.status.triage to 1.30.
const STROKE = 1.5;
const OTHER_STROKE: Record<string, string> = {
  "status.progress": "the 3.5 stroke is the pie's fill, drawn as a thick arc",
  "task.status.backlog": "a dotted ring: 1.75 round dots read as dots at 13 px",
};

const vendored = new Set(
  (catalog as { icons: { name: string; source?: string }[] }).icons
    .filter((icon) => icon.source === "chromium")
    .map((icon) => icon.name),
);

function box(name: string) {
  const ink = inkBounds(pack.icons[name].line);
  if (!ink) throw new Error(`${name} draws nothing`);
  const half = ink.stroke / 2;
  return {
    cx: (ink.x0 + ink.x1) / 2,
    cy: (ink.y0 + ink.y1) / 2,
    w: ink.x1 - ink.x0 + 2 * half,
    h: ink.y1 - ink.y0 + 2 * half,
  };
}

describe("icon pack geometry", () => {
  test("every glyph's ink is centred on 12,12, or is a named exception", () => {
    const off: string[] = [];
    for (const name of Object.keys(pack.icons)) {
      if (vendored.has(name) || Object.hasOwn(OFF_CENTER, name)) continue;
      const { cx, cy } = box(name);
      if (Math.abs(cx - 12) > CENTER_TOLERANCE || Math.abs(cy - 12) > CENTER_TOLERANCE)
        off.push(`${name} (${cx.toFixed(2)}, ${cy.toFixed(2)})`);
    }
    expect(off).toEqual([]);
  });

  test("every Line stroke draws at the pack's 1.5, or is a named exception", () => {
    const off: string[] = [];
    for (const name of Object.keys(pack.icons)) {
      if (vendored.has(name) || Object.hasOwn(OTHER_STROKE, name)) continue;
      const widths = new Set(
        pack.icons[name].line.filter((layer) => layer.op === "stroke").map((layer) => layer.w ?? STROKE),
      );
      for (const width of widths) if (Math.abs(width - STROKE) > 1e-6) off.push(`${name} (${width})`);
    }
    expect(off).toEqual([]);
  });

  test("every named exception still exists", () => {
    for (const name of [...Object.keys(OFF_CENTER), ...Object.keys(OTHER_STROKE)])
      expect(Object.hasOwn(pack.icons, name)).toBe(true);
  });

  // Leo, 2026-11-07: "Why is the puzzle icon so damn big?" #37608 fitted the browser toolbar's puzzle to
  // the back arrow; the pack's own puzzle (palette, sidebar app sections, Settings) still filled 19.3 of
  // the 24 grid. A full-square glyph reads bigger than an open one at one extent (SPEC coverage trim),
  // so the puzzle draws no larger than the magnifier it sits beside.
  for (const name of ["extension", "extension.crashed"]) {
    test(`${name} is centred and no larger than search`, () => {
      const puzzle = box(name);
      const search = box("search");
      expect(Math.abs(puzzle.cx - 12)).toBeLessThanOrEqual(0.25);
      expect(Math.abs(puzzle.cy - 12)).toBeLessThanOrEqual(0.25);
      expect(Math.max(puzzle.w, puzzle.h)).toBeLessThanOrEqual(Math.max(search.w, search.h) + 0.5);
    });
  }
});
