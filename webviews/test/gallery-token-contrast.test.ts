// Every gallery variant is rendered with the app theme's token sheet. Keep the shared
// foreground/background contract checked in both color schemes so a new token cannot put
// light ink on a light surface (or dark ink on a dark surface).
import { expect, test } from "bun:test";
import { readShippedThemes } from "../dev-server/galleryHost";
import { themeIsDark } from "../src/gallery/theme/ghostty";
import { APP_ACCENTS, contrastReport, deriveAppTheme } from "../src/theme/appTheme";

test("gallery light and dark themes keep every text/background token pair readable", () => {
  const themes = readShippedThemes();
  const schemes = new Set(themes.map((theme) => (themeIsDark(theme) ? "dark" : "light")));
  expect([...schemes].sort()).toEqual(["dark", "light"]);

  const failures = themes.flatMap((theme) =>
    APP_ACCENTS.flatMap((accent) =>
      contrastReport(deriveAppTheme(theme, accent))
        .filter((pair) => !pair.pass)
        .map(
          (pair) =>
            `${theme.name} (${themeIsDark(theme) ? "dark" : "light"}) ${accent}: ` +
            `${pair.token} on ${pair.on} ${pair.ratio.toFixed(2)} < ${pair.min.toFixed(1)}`,
        ),
    ),
  );
  expect(failures).toEqual([]);
});
