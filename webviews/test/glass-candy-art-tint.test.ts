// Glass tint that follows the art (src/gallery/theme/artTint.ts, gallery ui.glass-candy): the art's
// leading color is the vivid one, its floor and ceiling bound every pixel, and the tint keeps the
// theme's primary and secondary text 4.5:1 over any part of the art, in every shipped theme, over a
// calm art, a vivid one and the worst case (pure black beside pure white).
import { describe, expect, test } from "bun:test";
import { readShippedThemes } from "../dev-server/galleryHost";
import { artGlassTint, artPalette, worstOverArt } from "../src/gallery/theme/artTint";
import { composited, contrast, MINIMUM_TEXT_CONTRAST, rgb, withAlpha, type ThemeRGB } from "../src/gallery/theme/tokens";
import { themeTokens } from "../src/gallery/theme/web";

/** RGBA bytes of `colors`, each repeated `weight` times. */
function pixels(...colors: [ThemeRGB, number][]): Uint8ClampedArray {
  const bytes: number[] = [];
  for (const [color, weight] of colors)
    for (let n = 0; n < weight; n += 1)
      bytes.push(Math.round(color.red * 255), Math.round(color.green * 255), Math.round(color.blue * 255), 255);
  return Uint8ClampedArray.from(bytes);
}

const NIGHT_BLUE = rgb(0.1, 0.18, 0.45);
const STAR_YELLOW = rgb(0.95, 0.82, 0.25);
const GREY = rgb(0.5, 0.5, 0.52);
const ARTS = {
  calm: pixels([rgb(0.42, 0.46, 0.5), 40], [rgb(0.55, 0.58, 0.6), 30]),
  vivid: pixels([NIGHT_BLUE, 50], [STAR_YELLOW, 12], [GREY, 20]),
  worst: pixels([rgb(0, 0, 0), 10], [rgb(1, 1, 1), 10], [rgb(1, 0, 0), 4]),
};

describe("artPalette", () => {
  test("the leading color is the vivid mass, not the grey, and the floor and ceiling bound every sample", () => {
    const palette = artPalette(ARTS.vivid);
    expect(contrast(palette.dominant[0]!, NIGHT_BLUE)).toBeLessThan(1.1);
    expect(palette.dominant.some((color) => contrast(color, STAR_YELLOW) < 1.1)).toBe(true);
    expect(palette.low.blue).toBeCloseTo(0.25, 1);
    expect(palette.high.red).toBeCloseTo(0.95, 1);
  });

  test("transparent samples are skipped; nothing seen gives no leading color", () => {
    expect(artPalette(Uint8ClampedArray.from([255, 0, 0, 0])).dominant).toEqual([]);
  });
});

describe("artGlassTint", () => {
  const themes = readShippedThemes();
  test("at least 40 shipped themes to check", () => expect(themes.length).toBeGreaterThanOrEqual(40));

  for (const [name, art] of Object.entries(ARTS))
    test(`${name} art: every shipped theme's text keeps 4.5:1 on the tint, following and neutral`, () => {
      const palette = artPalette(art);
      const failures: string[] = [];
      for (const theme of themes) {
        const tokens = themeTokens(theme);
        const inks = [tokens.textPrimary, tokens.textSecondary];
        const wash = withAlpha(tokens.windowBackground, 0.28);
        for (const follow of [0, 0.5]) {
          const { tint, worst } = artGlassTint({ surface: tokens.surfaceBackground, inks, palette, wash, follow });
          // Recheck from scratch over the corners the art can reach, with the wash over them.
          const corners = [palette.low, palette.high].map((corner) => composited(wash, corner));
          const again = worstOverArt(tint, inks, corners);
          if (again < MINIMUM_TEXT_CONTRAST || Math.abs(again - worst) > 1e-9)
            failures.push(`${theme.name} follow ${follow}: ${again.toFixed(2)}`);
          if (tint.alpha > 1 || tint.alpha < 0.3) failures.push(`${theme.name}: alpha ${tint.alpha}`);
        }
      }
      expect(failures).toEqual([]);
    });

  test("over a calm art the tint stays glass (translucent) and follows the art's hue", () => {
    const tokens = themeTokens(readShippedThemes().find((theme) => theme.name === "Apple System Colors")!);
    const palette = artPalette(ARTS.vivid);
    const neutral = artGlassTint({
      surface: tokens.surfaceBackground,
      inks: [tokens.textPrimary],
      palette: artPalette(ARTS.calm),
      follow: 0,
    });
    expect(neutral.tint.alpha).toBeLessThan(0.9);
    const following = artGlassTint({ surface: tokens.surfaceBackground, inks: [tokens.textPrimary], palette, follow: 0.5 });
    expect(following.follow).toBeGreaterThan(0);
    // Moved toward the night blue: more blue than red, unlike the neutral surface.
    expect(following.tint.blue - following.tint.red).toBeGreaterThan(
      tokens.surfaceBackground.blue - tokens.surfaceBackground.red,
    );
  });
});
