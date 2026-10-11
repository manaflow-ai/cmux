// A composer location menu keeps the side it chose when it opened (cx-ncc.53). The gallery's
// `agent-pane.composer-context-side` play opens the folder popover where its full list does not fit
// above the chip, filters it until it would, and fails if the popup changes side; this runs the
// play in Chromium and checks it passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-location-side.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-location-side: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer location side", () => test("chromium", () => {}));
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the folder popover stays on the side it opened on while a filter shrinks it", async () => {
    const page = await browser!.newPage({ viewport: { width: 620, height: 560 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    // A cold dev server re-optimizes its deps on the first page and can leave that page without
    // its modules (it never reports ready): load it again once the optimizer has settled.
    const url = `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer-context-side&variant=filter-keeps-side`;
    for (let attempt = 1; ; attempt++) {
      await page.goto(url);
      const ready = await page
        .waitForFunction(
          () => {
            const ready = document.documentElement.dataset.galleryReady;
            return ready === "1" || ready === "error";
          },
          undefined,
          { timeout: 30_000 },
        )
        .then(() => true)
        .catch((error: unknown) => {
          if (attempt >= 3) throw error;
          return false;
        });
      if (ready) break;
    }
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    expect(result.play, result.report).toBe("pass");
  });
});
