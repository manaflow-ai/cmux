// cmux-web-test-timeout: 240
// Settings › Import in the gallery shows the import suggestion cards, as the app does: the host
// sends the list (`import_suggestions`) by default since #22710. Regression: the gallery's host
// lists had none, so the section drew nothing, the stage waited for a card until its 5 s bound,
// and gallery health reported pages.settings#import and #import-customized as "the stage reported
// an error".
//
// Real Chromium from Playwright, on the gallery's dev server; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, reloaded, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-settings-import.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("gallery-settings-import: skipping (run `bunx playwright install chromium`)");
    describe.skip("settings import gallery", () => test("chromium", () => {}));
    return;
  }
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
    await warmGalleryFrame(vite, ["pages.settings"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["import", "import-customized"])
    test(`pages.settings#${variant} shows the import cards`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      const port = (vite!.httpServer!.address() as { port: number }).port;
      for (;;) {
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant })}`);
          await page.waitForFunction(
            () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
            undefined,
            {
              timeout: 90_000,
            },
          );
          break;
        } catch (error) {
          if (!reloaded(error)) throw error;
        }
      }
      const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
      const cards = await page.locator('[data-card="importSuggestions"] [data-import-card]').count();
      await page.close();
      expect(errors).toEqual([]);
      expect(ready).toBe("1");
      expect(cards).toBeGreaterThan(0);
    });
});
