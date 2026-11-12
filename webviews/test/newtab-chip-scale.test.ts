// cmux-web-test-timeout: 300
// The New Tab composer's chips are one set (Lawrence 2026-11-09, of the folder and computer chips
// above the box and the permission and model chips under it: "all font sizes and icons sizes here
// need to be more consistent"). Base drew the chips above at 12 px text with 14 px icons and 14 px
// chevrons, and the chips under at 13 px text with an 18 px shield, a 16 px model mark and a 12 px
// chevron. Every chip now takes the composer's chip tokens: one label size and weight, one leading
// glyph size and one chevron size, each on the icon scale (scripts/check-icon-scale.ts), and the
// label's ink centered on its glyph. Measured in Chromium from the gallery, light and dark, with a
// project, without one and with a machine picked, at a wide and a narrow width.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { measureNewTabChips, type ChipMeasure } from "./support/newTabChipScale";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-chip-scale.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.new-tab-icon-column";
  const STATES = ["no-project", "project", "machine"];
  const WIDTHS = [760, 1040];
  const THEMES = { light: "Apple System Colors Light", dark: "Apple System Colors" };
  const LABEL = { size: 13, weight: 400 };
  const GLYPH = 16;
  const CHEVRON = 12;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "project" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const state of STATES)
    for (const width of WIDTHS)
      for (const [look, theme] of Object.entries(THEMES))
        test(`${state} ${width}px ${look}: every chip draws one label size, one glyph size and one chevron size`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: 360 }, deviceScaleFactor: 2 });
          try {
            const port = (vite!.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: state, theme })}`);
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
              timeout: 60_000,
            });
            await page.evaluate(() => document.fonts.ready);
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            const chips: ChipMeasure[] = await page.evaluate(measureNewTabChips);
            const where = `${state} ${width}px ${look}: ${JSON.stringify(chips)}`;
            // The two chips above the box and the permission and model chips under it.
            expect(chips.filter((chip) => chip.chip.startsWith("location")).length, where).toBeGreaterThanOrEqual(1);
            expect(
              chips.some((chip) => chip.chip === "access"),
              where,
            ).toBe(true);
            expect(
              chips.some((chip) => chip.chip === "model"),
              where,
            ).toBe(true);
            for (const chip of chips) {
              // The model's mark is a setting (modelChipIcon.ts); every other chip always draws its glyph.
              if (chip.chip !== "model" || chip.glyph !== null)
                expect(chip.glyph, `${chip.chip} glyph; ${where}`).toBe(GLYPH);
              if (chip.label) expect(chip.label, `${chip.chip} label; ${where}`).toEqual(LABEL);
              if (chip.chevron !== null) expect(chip.chevron, `${chip.chip} chevron; ${where}`).toBe(CHEVRON);
              if (chip.glyphOffset !== null)
                expect(
                  Math.abs(chip.glyphOffset),
                  `${chip.chip} label off its glyph's line; ${where}`,
                ).toBeLessThanOrEqual(0.5);
            }
          } finally {
            await page.close();
          }
        });
});
