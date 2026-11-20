// Secondary text on glass, fitted per level (cmuxterm-hq docs/reading/2026-11-19-glass-field-study.md,
// gap 1). Leo: "Did we ever figure out why our "glass" was so stupid looking". The lab measured secondary
// text drawn as a fixed 60 to 64% mix at 4.38:1 on the menu over bright art and 3.43:1 on its selected row:
// the text, not the glass, was the weak link. Each glass level's secondary (design-scale.json
// glass[].secondary, --ds-glass-<level>-secondary) is the least share of the ink that keeps 4.5:1 over the
// level's tint laid on pure black and on pure white, on a plain row and on a selected row (the highlight
// white 12% in dark, black 7% in light), the tooltip's fit (TooltipSurface.swift). This re-measures it, so
// a tint that moves without its secondary fails here.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import designScale from "../../schemas/design-scale/design-scale.json";

type RGB = [number, number, number];
type Scheme = "light" | "dark";

// The lab's surfaces and inks (lab/recipes.mjs, lab/lab.mjs): the popup surface and the text.
const SURFACE: Record<Scheme, RGB> = { dark: [0x1c, 0x1c, 0x1e], light: [0xf5, 0xf5, 0xf7] };
const INK: Record<Scheme, RGB> = { dark: [255, 255, 255], light: [0x1d, 0x1d, 0x1f] };
const HIGHLIGHT: Record<Scheme, [RGB, number]> = { dark: [[255, 255, 255], 0.12], light: [[0, 0, 0], 0.07] };
const BACKDROPS: RGB[] = [
  [0, 0, 0],
  [255, 255, 255],
];
// A dark level whose tint carries no text at 4.5:1 over pure white, primary included (the 60% dark
// tint: primary 3.58:1). Its secondary is the 90% cap until the tint floor (gap 1, second half) lands;
// the number here is what it holds, so it can only go up.
const SHORT: Record<string, number> = { "chrome-dark": 3.23, "chip-dark": 3.23 };

const lin = (c: number) => {
  const v = c / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
};
const luminance = ([r, g, b]: RGB) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
const contrast = (a: RGB, b: RGB) => {
  const [x, y] = [luminance(a), luminance(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
};
const over = (top: RGB, alpha: number, under: RGB): RGB =>
  under.map((c, i) => alpha * top[i]! + (1 - alpha) * c) as RGB;

/** The worst contrast of the ink at `share` on the level's rows over black and white. */
function worst(tint: number, scheme: Scheme, share: number): number {
  const [highlight, alpha] = HIGHLIGHT[scheme];
  let least = Infinity;
  for (const backdrop of BACKDROPS) {
    const glass = over(SURFACE[scheme], tint / 100, backdrop);
    for (const row of [glass, over(highlight, alpha, glass)])
      least = Math.min(least, contrast(over(INK[scheme], share / 100, row), row));
  }
  return least;
}

const levels = designScale.glass.filter((level) => level.kind === "level") as {
  name: string;
  tint: number;
  secondary: Record<Scheme, number>;
}[];

for (const level of levels)
  for (const scheme of ["light", "dark"] as const)
    test(`${level.name}, ${scheme}: secondary text keeps 4.5:1 on plain and selected rows`, () => {
      const share = level.secondary[scheme];
      const short = SHORT[`${level.name}-${scheme}`];
      if (short !== undefined) {
        expect(share, "the most a secondary can be and still read as one").toBe(90);
        expect(worst(level.tint, scheme, share)).toBeGreaterThanOrEqual(short - 0.005);
        expect(worst(level.tint, scheme, 100), "the tint holds no text at 4.5:1 yet").toBeLessThan(4.5);
        return;
      }
      expect(worst(level.tint, scheme, share)).toBeGreaterThanOrEqual(4.5);
      // The least share that does: one point less fails, so the secondary stays as quiet as it can be.
      expect(worst(level.tint, scheme, share - 1)).toBeLessThan(4.5);
      // The old fixed 62% mix failed on every level.
      expect(worst(level.tint, scheme, 62)).toBeLessThan(4.5);
    });

test("each glass level draws its fitted secondary, and desktop.css carries it light and dark", () => {
  const desktop = readFileSync(new URL("../src/pages/shared/desktop.css", import.meta.url), "utf8");
  for (const level of levels)
    expect(desktop).toContain(
      `--ds-glass-${level.name}-secondary: light-dark(color-mix(in srgb, var(--cmux-text, CanvasText) ${level.secondary.light}%, transparent), color-mix(in srgb, var(--cmux-text, CanvasText) ${level.secondary.dark}%, transparent));`,
    );
  const glass = readFileSync(new URL("../src/ui/glass/glass.css", import.meta.url), "utf8");
  for (const name of ["chrome", "menu", "popover", "chip"])
    expect(glass).toContain(`--glass-secondary: var(--ds-glass-${name}-secondary);`);
  for (const read of ["--cmux-text-secondary", "--ds-color-muted", "--agent-muted"])
    expect(glass).toContain(`${read}: var(--glass-secondary);`);
});
