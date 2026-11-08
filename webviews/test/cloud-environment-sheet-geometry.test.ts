// cmux-web-test-timeout: 300
// The Edit cloud environment sheet keeps its heading and its Cancel/Save row inside the sheet's visible
// box however many secrets unfold their delivery (design/environment-sheet.md "Secret row"): only the
// fields scroll between them. A review found the actions clipped below the sheet with three secrets open.
// Chromium on the gallery stage, `cloud.environment-sheet/secret-many-expanded`, at two window heights.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cloud-environment-sheet-geometry.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "cloud.environment-sheet";
  const VARIANT = "secret-many-expanded";
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch (error) {
    console.warn(
      `cloud-environment-sheet-geometry: skipping, chromium did not launch (${String(error).split("\n")[0]})`,
    );
    describe.skip("cloud environment sheet geometry", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const height of [640, 900])
    test(`every header open, ${height} px tall: the heading and actions stay inside the sheet; the fields scroll`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 700 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        await page.locator(".cloud-environment-sheet .env-secret").first().waitFor();
        const open = page.locator('.env-fold[data-open] > .env-fold-body > .env-disclosure[aria-expanded="false"]');
        while ((await open.count()) > 0) await open.first().click();
        // The folds settle (the standard motion step is 180 ms); measure their end state.
        await page.waitForFunction(() =>
          document.getAnimations().every((animation) => animation.playState !== "running"),
        );
        const box = await page.evaluate(() => {
          const rect = (selector: string) => {
            const node = document.querySelector(selector);
            if (!node) throw new Error(`missing ${selector}`);
            const { top, bottom, left, right } = node.getBoundingClientRect();
            return { top, bottom, left, right };
          };
          const body = document.querySelector<HTMLElement>(".cloud-environment-sheet .env-body")!;
          return {
            sheet: rect(".cloud-environment-sheet"),
            heading: rect(".cloud-environment-sheet .env-heading"),
            actions: rect(".cloud-environment-sheet .env-actions"),
            save: rect(".cloud-environment-sheet .env-primary"),
            viewport: window.innerHeight,
            scrolls: body.scrollHeight > body.clientHeight,
            secrets: document.querySelectorAll(".cloud-environment-sheet .env-secret").length,
          };
        });
        console.log(`cloud environment sheet, ${height} px:`, JSON.stringify(box));
        expect(box.secrets).toBeGreaterThanOrEqual(9);
        const inside = (part: { top: number; bottom: number }) =>
          part.top >= box.sheet.top - TOLERANCE && part.bottom <= box.sheet.bottom + TOLERANCE;
        expect(inside(box.heading)).toBe(true);
        expect(inside(box.actions)).toBe(true);
        expect(inside(box.save)).toBe(true);
        expect(box.sheet.bottom).toBeLessThanOrEqual(box.viewport + TOLERANCE);
        // Nine open secrets are taller than either window: the fields scroll, not the sheet.
        expect(box.scrolls).toBe(true);
      } finally {
        await page.close();
      }
    });
});
