// A web menu's own glass follows the theme's menu veil, as a native menu does (design/glass-system.md, rule 5):
// over a white and a black page the theme's text reads at 4.5:1 (or what it reads on its own surface, less 0.05)
// and the glass secondary ink (the text at --ds-glass-ink-secondary, 68%) at 3:1, in every shipped theme. The page
// lays a menu's own tint at 100% − (100% − its level tint) × --cmux-menu-clear (glass.css "A MENU'S OWN GLASS"), the
// share WebTheme.swift sends (GlassMenuMaterial.webClear); without it the 80% light and 72% dark tints read Rose Pine
// Dawn's text at 2.6:1 over a black page. A theme whose veil reaches the glass rule's 90% cap (a clear of 1/6) keeps
// the cap: its readings there must stay at least the floors below (Hot Dog Stand's text 4.19:1, its secondary 2.61:1).
import { expect, test } from "bun:test";
import { readShippedThemes } from "../dev-server/galleryHost";
import { themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { BLACK, composited, contrast, WHITE, withAlpha } from "../src/gallery/theme/tokens";

/** --ds-transient-web-tint light and dark (desktop.css; TransientMaterial.webTint, webTintDark). */
const LEVEL_TINT = { light: 0.8, dark: 0.72 };
/** --ds-glass-ink-secondary. */
const SECONDARY_SHARE = 0.68;
/** The clear at the 90% veil cap, (1 − 90%) / (1 − 40%). */
const CAP_CLEAR = 1 / 6;
/** At the cap: the least share of the text's wanted contrast, and the secondary ink's floor (the legible 2.5:1). */
const CAP_PRIMARY_SHARE = 0.9;
const CAP_SECONDARY = 2.5;

test("a web menu's own glass keeps the theme's text readable over a white and a black page in every shipped theme", () => {
  const themes = readShippedThemes();
  expect(themes.length).toBeGreaterThan(500);
  const misses: string[] = [];
  for (const theme of themes) {
    const tokens = themeTokens(theme);
    const clear = Number(webThemePayload(tokens).variables["--cmux-menu-clear"] ?? "1");
    const tint = 1 - (1 - (tokens.isDark ? LEVEL_TINT.dark : LEVEL_TINT.light)) * clear;
    const surface = withAlpha(tokens.surfaceBackground, 1);
    const text = withAlpha(tokens.textPrimary, 1);
    const wants = Math.min(4.5, contrast(text, surface) - 0.05);
    const capped = clear <= CAP_CLEAR + 0.001;
    for (const [name, page] of [
      ["white", WHITE],
      ["black", BLACK],
    ] as const) {
      const glass = composited(withAlpha(surface, tint), page);
      const primary = contrast(text, glass);
      const secondary = contrast(composited(withAlpha(text, SECONDARY_SHARE), glass), glass);
      const reads = capped
        ? primary >= wants * CAP_PRIMARY_SHARE && secondary >= CAP_SECONDARY
        : primary >= wants && secondary >= 3;
      if (!reads)
        misses.push(
          `${theme.name} over ${name}: text ${primary.toFixed(2)}, secondary ${secondary.toFixed(2)} at tint ${(tint * 100).toFixed(1)}%`,
        );
    }
  }
  expect(misses).toEqual([]);
});
