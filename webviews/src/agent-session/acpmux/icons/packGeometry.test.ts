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
  "agent.bot": "drawn before this check: antenna above the head",
  "composer.steer": "drawn before this check",
  "message.delivered": "drawn before this check: the double check's tail",
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

  test("every named exception still exists", () => {
    for (const name of Object.keys(OFF_CENTER)) expect(Object.hasOwn(pack.icons, name)).toBe(true);
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
