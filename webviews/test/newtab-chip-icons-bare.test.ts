// The New Tab composer's chip glyphs are bare (2026-11-23, of the grey squares behind the folder,
// machine, + and shield glyphs: "why is there a background icon grey thing here? we need to remove
// it"). Those squares were the Tiles arm of iconColumn.experiment.ts, then the shipped arm; pad ships
// again. Measured in Chromium from the gallery with no arm forced, so the test follows whatever arm
// ships: at every density and in light and dark, no chip glyph (folder or project badge, machine,
// + and the permission shield) draws a fill, an outline or a shadow of its own.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { newTabIconColumn } from "../src/agent-session/acpmux/newtab/iconColumn.experiment";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Glyph = { where: string; background: string; outline: string; shadow: string };

await requireBrowserLane("newtab-chip-icons-bare.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.new-tab-icon-column";
  const STATES = ["no-project", "project", "machine"];
  const DENSITIES = [0.75, 1, 1.5];
  const THEMES = { light: "Apple System Colors Light", dark: "Apple System Colors" };
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
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
    for (const density of DENSITIES)
      for (const [look, theme] of Object.entries(THEMES))
        test(`${state} ${look} density ${density}: no chip glyph draws a tile`, async () => {
          const page = await browser!.newPage({ viewport: { width: 760, height: 360 }, deviceScaleFactor: 2 });
          try {
            const port = (vite!.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: state, theme })}`);
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
              timeout: 60_000,
            });
            await page.evaluate((density) => {
              document.documentElement.style.setProperty("--cmux-density-scale", String(density));
              document.documentElement.style.setProperty("--cmux-density-text-scale", String(density));
            }, density);
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            const { arm, glyphs } = await page.evaluate(() => {
              const picked = [
                ...document.querySelectorAll(
                  ".nt-above .acpmux-location-button > :is(svg, .acpmux-project-badge):first-child, .nt-box .acpmux-composer-plus svg, .nt-foot .acpmux-access-trigger > .acpmux-icon:first-child",
                ),
              ];
              return {
                arm: document.querySelector<HTMLElement>(".nt-composer")?.dataset.iconColumn ?? null,
                glyphs: picked.map((element): Glyph => {
                  const style = getComputedStyle(element);
                  const button = element.closest("button");
                  return {
                    where: button?.className.toString() ?? element.tagName,
                    background: style.backgroundColor,
                    outline: style.outlineStyle === "none" ? "none" : `${style.outlineWidth} ${style.outlineStyle}`,
                    shadow: style.boxShadow,
                  };
                }),
              };
            });
            expect(arm).toBe(newTabIconColumn.defaultArm);
            // Every state shows two location chips (the folder or project, and This Mac), the + and the
            // shield (newtab-chip-scale.test.ts), so a glyph that stops matching fails here.
            expect(glyphs.length).toBeGreaterThanOrEqual(4);
            const transparent = (color: string) =>
              color === "transparent" || /^rgba\(0, 0, 0, 0\)$/.test(color) || color.endsWith("/ 0)");
            for (const glyph of glyphs) {
              expect({ ...glyph, background: transparent(glyph.background) ? "none" : glyph.background }).toEqual({
                where: glyph.where,
                background: "none",
                outline: "none",
                shadow: "none",
              });
            }
          } finally {
            await page.close();
          }
        });
});
