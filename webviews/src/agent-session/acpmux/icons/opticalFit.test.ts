import { describe, expect, test } from "bun:test";
import bundled from "./cmuxIcons.json";
import { INK_BOX, inkBounds, opticalRowFit } from "./opticalFit";
import type { IconPack } from "./types";

const pack = bundled as IconPack;

// Session Info's icon column (Leo, 2026-11-01: "the symbols we have are a little strange looking in
// terms of alignment"): the machine kinds, the project, the repository, the branch, Remote Control,
// Context and Connectors. Before the fit, their ink ran from 13 units tall (machine.mac) to 20 (the
// phone, past the row's 19-unit crop), and the folder sat half a unit low.
const COLUMN = [
  "machine.mac",
  "machine.remote",
  "cloud",
  "folder",
  "git.worktree",
  "brand.github",
  "git.branch",
  "device.phone",
  "context.usage",
  "extension",
];

describe("optical row fit", () => {
  test("measures exact curve bounds, not the control points", () => {
    // A circle of radius 8.5 about (12, 12), four cubics, as the pack draws one.
    const ink = inkBounds([
      {
        d: "M20.5 12C20.5 16.694 16.694 20.5 12 20.5C7.306 20.5 3.5 16.694 3.5 12C3.5 7.306 7.306 3.5 12 3.5C16.694 3.5 20.5 7.306 20.5 12Z",
        op: "stroke",
        w: 1.5,
      },
    ]);
    expect(ink).toEqual({ x0: 3.5, y0: 3.5, x1: 20.5, y1: 20.5, stroke: 1.5 });
  });

  for (const name of COLUMN) {
    test(`${name} fills one ink box, centred, at the pack's stroke`, () => {
      const layers = pack.icons[name].line;
      const ink = inkBounds(layers)!;
      const fit = opticalRowFit(layers);
      const [x, y, span] = fit.viewBox.split(" ").map(Number);
      // Ink centred on the slot.
      expect(x + span / 2).toBeCloseTo((ink.x0 + ink.x1) / 2, 2);
      expect(y + span / 2).toBeCloseTo((ink.y0 + ink.y1) / 2, 2);
      // In the row's 19-unit crop, every stroke draws at its pack width...
      const toCrop = 19 / span;
      layers.forEach((layer, index) => {
        if (layer.op === "stroke") expect(fit.layers[index].w! * toCrop).toBeCloseTo(layer.w ?? 1.5, 2);
      });
      // ...and the ink's longer side, stroke included, spans INK_BOX units.
      const longest = Math.max(ink.x1 - ink.x0, ink.y1 - ink.y0);
      expect(longest * toCrop + ink.stroke).toBeCloseTo(INK_BOX, 1);
    });
  }

  test("returns the same fit for the same drawing", () => {
    const layers = pack.icons.folder.line;
    expect(opticalRowFit(layers)).toBe(opticalRowFit(layers));
  });
});
