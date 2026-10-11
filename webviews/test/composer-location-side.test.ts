// A composer location menu keeps the side it chose when it opened (cx-ncc.53). The gallery's
// `agent-pane.composer-context-side` play opens the folder popover where its full list does not fit
// above the chip, filters it until it would, and fails if the popup changes side; this runs the
// play in Chromium and checks it passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
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
    // A cold dev server re-optimizes its deps on the first page it serves and can delete chunks
    // that page is still loading (it reports "error" or never ready). Warm it with a throwaway
    // page so the measured one loads against settled deps.
    const warm = await browser.newPage();
    await load(warm);
    await warm.close();
  });

  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-context-side&variant=filter-keeps-side`;

  /// Loads the gallery frame until it reports ready, again after an error or a timeout.
  const load = async (page: Page) => {
    for (let attempt = 1; ; attempt++) {
      await page.goto(url());
      const ready = await page
        .waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 20_000 })
        .then((handle) => handle.jsonValue())
        .catch(() => undefined);
      if (ready === "1") return;
      if (attempt >= 4) throw new Error(`the gallery frame did not load (${String(ready)})`);
    }
  };
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the folder popover stays on the side it opened on while a filter shrinks it", async () => {
    const page = await browser!.newPage({ viewport: { width: 620, height: 560 } });
    await load(page);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    // The play throws when the side or placement is wrong ("fail"); "warn" is the stage's own
    // popup-layer measure, taken as the open animation settles.
    expect(result.play === "pass" || result.play === "warn", result.report).toBe(true);
    expect(result.report).not.toContain('"error"');
  });
});
