// The app theme's shared vectors (schemas/theme/app-theme-vectors.json), which the Swift port replays:
// the committed file must equal a fresh export.
import { expect, test } from "bun:test";

test("the Swift port's vectors are current (schemas/theme/app-theme-vectors.json)", async () => {
  const { vectors, VECTORS_PATH } = await import("../scripts/theme/export-app-theme-vectors");
  const fs = await import("node:fs");
  expect(fs.readFileSync(VECTORS_PATH, "utf8")).toBe(vectors());
});

// appearance.accent: the theme's own hue reaches the accent, and every bundled theme still meets
// the WCAG contract with every accent.
test("a theme accent takes the palette's hue and keeps every contract pair", async () => {
  const { readShippedThemes } = await import("../dev-server/galleryHost");
  const { APP_ACCENTS, contrastReport, deriveAppTheme } = await import("../src/theme/appTheme");
  const themes = readShippedThemes();
  const rosePine = themes.find((theme) => theme.name === "Rose Pine")!;
  expect(deriveAppTheme(rosePine, "neutral").tokens.accent).toBe("#e1e1e1");
  expect(deriveAppTheme(rosePine, "theme").tokens.accent).toBe("#c4a7e7");
  const failures = themes.flatMap((theme) =>
    APP_ACCENTS.flatMap((accent) =>
      contrastReport(deriveAppTheme(theme, accent))
        .filter((pair) => !pair.pass)
        .map((pair) => `${theme.name} ${accent}: ${pair.token} on ${pair.on} ${pair.ratio.toFixed(2)}`),
    ),
  );
  expect(failures).toEqual([]);
});
