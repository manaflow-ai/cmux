// cmux-web-test-timeout: 300
// l10n-allow-file: gallery fixture labels and regression diagnostics.
// The rate-limit card's Details disclosure must keep its reserved action-row slot while its raw
// error opens below it. Leo, 2026-11-12: "this details moves aroud".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("turn-error-details-placement.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.turn-error-card";
  const VARIANTS = ["details-placement-wide", "details-placement-narrow", "details-placement-long"];
  const WIDTHS = [360, 760];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0]! } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of VARIANTS)
    for (const width of WIDTHS)
      test(`${variant} keeps Details in place at ${width}px`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 360 }, deviceScaleFactor: 2 });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, height: 360 })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          const summary = page.locator(".cv-turn-error__details summary").first();
          await summary.waitFor();
          const before = await summary.boundingBox();
          expect(before).not.toBeNull();
          await summary.click();
          await page.locator(".cv-turn-error__details[open]").waitFor();
          const after = await summary.boundingBox();
          expect(after).not.toBeNull();
          expect(after!.x).toBe(before!.x);
          expect(after!.y).toBe(before!.y);
          expect(after!.width).toBe(before!.width);
          expect(await page.locator(".cv-turn-error__raw").count()).toBe(1);
          if (process.env.CMUX_HOVER_CAPTURE_DIR)
            await page.screenshot({
              path: path.join(process.env.CMUX_HOVER_CAPTURE_DIR, `turn-error-details-${variant}-${width}.png`),
            });
        } finally {
          await page.close();
        }
      });
});
