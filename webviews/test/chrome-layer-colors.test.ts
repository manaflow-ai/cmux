// The gallery's mock app paints the same chrome colours as the native window: the sidebar list, its footer and
// the titlebar row, in each case schemas/theme/chrome-layer-colors.json records from the app
// (ChromeLayerColorTests in CmuxNextAppTests). Leo, 2026-11-11, after #39984 dimmed the sidebar: "bro why is the
// sidebar now a different color?" A change to the gallery's chrome fills or the theme tokens under them fails
// here, as a change to the app's fails there.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { readShippedThemes } from "../dev-server/galleryHost";
import { chromeHex, chromeRegions, type ChromeRegion } from "../src/gallery/mock-app/chrome";
import { themeTokens } from "../src/gallery/theme/web";

type Case = { case: string; theme: string; isDark: boolean; background: string } & Record<ChromeRegion, string>;

const file = JSON.parse(
  readFileSync(new URL("../../schemas/theme/chrome-layer-colors.json", import.meta.url), "utf8"),
) as { cases: Case[] };
const REGIONS: ChromeRegion[] = ["sidebar", "footer", "titlebar"];

test("the recorded file holds the default themes, plain and over a picture", () => {
  expect(file.cases.map((item) => item.case).sort()).toEqual(["dark", "dark-image", "light", "light-image"]);
});

test("the mock app's chrome paints the native window's recorded colours", () => {
  const themes = readShippedThemes();
  const differences = file.cases.flatMap((item) => {
    const theme = themes.find((candidate) => candidate.name === item.theme);
    if (!theme) return [`${item.case}: no shipped theme ${item.theme}`];
    const regions = chromeRegions(themeTokens(theme), item.background !== "none");
    return REGIONS.flatMap((region) =>
      chromeHex(regions[region]) === item[region]
        ? []
        : [`${item.case} ${region}: the app paints ${item[region]}, the mock app ${chromeHex(regions[region])}`],
    );
  });
  expect(differences).toEqual([]);
});
