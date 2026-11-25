// cmux-web-test-timeout: 300
// The New Tab composer's chips in one ink on two straight edges (Lawrence 2026-11-09: "the brightness
// of text needs to be more well thought out, like think what do we want to emphasize, if anything at
// all (maybe we should just make them all the same color); also left alignment and right alignment
// these things needs to be good"). At rest no chip is emphasized: the folder, the computer, the
// permission mode and the model draw their labels and glyphs in one color (hover, an open menu and
// Full access still change it; they carry state). The left column, the folder chip over the box and
// the permission chip under it, starts its glyphs on one edge and its labels on one edge (the folder's glyph box on the
// + and shield column). The right column ends the model's text where the Send glyph's
// ink ends. Base drew the permission chip one step dimmer than the rest, its label 2 px right of the
// folder's, and the model's text 12 px past Send. Measured in Chromium, light and dark.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { measureNewTabEdges, type NewTabEdges } from "./support/newTabChipScale";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-chip-ink-edges.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.new-tab-icon-column";
  const STATES = ["no-project", "project"];
  const WIDTHS = [760, 1040];
  const THEMES = { light: "Apple System Colors Light", dark: "Apple System Colors" };
  const EDGE = 0.5;
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

  const near = (a: number | null, b: number | null) => (a === null || b === null ? Number.NaN : Math.abs(a - b));

  for (const state of STATES)
    for (const width of WIDTHS)
      for (const [look, theme] of Object.entries(THEMES))
        test(`${state} ${width}px ${look}: one chip ink, a straight left column and a straight right column`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: 360 }, deviceScaleFactor: 2 });
          try {
            const port = (vite!.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: state, theme })}`);
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
              timeout: 60_000,
            });
            await page.evaluate(() => document.fonts.ready);
            // Nothing hovered: the pointer rests off the page, so every chip shows its resting ink.
            await page.mouse.move(0, 0);
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            const m: NewTabEdges = await page.evaluate(measureNewTabEdges);
            const where = `${state} ${width}px ${look}: ${JSON.stringify(m)}`;
            const inks = Object.values(m.inks);
            expect(inks.length, where).toBeGreaterThanOrEqual(5);
            expect(
              inks.every((ink) => typeof ink === "string"),
              where,
            ).toBe(true);
            expect(new Set(inks).size, `one ink; ${where}`).toBe(1);
            expect(near(m.folderGlyphLeft, m.shieldGlyphLeft), `glyphs' left edge; ${where}`).toBeLessThanOrEqual(EDGE);
            // The folder, + and the shield share one glyph box column (#41207, newtab-icon-column.test.ts
            // measures + on it); each glyph's own side bearing sets its ink inside that box.
            expect(near(m.folderLabelLeft, m.modeLabelLeft), `labels' left edge; ${where}`).toBeLessThanOrEqual(EDGE);
            expect(near(m.sendInkRight, m.modelLabelRight), `right edge; ${where}`).toBeLessThanOrEqual(EDGE);
          } finally {
            await page.close();
          }
        });
});
