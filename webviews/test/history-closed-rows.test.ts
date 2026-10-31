// Remove and Clear on the History page's Closed rows (cx-gzh.30). The daemon's history.entries.remove
// and history.clear delete closed items now, so the page offers Clear History under the Closed chip.
// The gallery play drives the real page in Chromium against the gallery host: Remove on a Closed row
// takes it out, and Clear History > All Time under the Closed chip takes the rest.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("history-closed-rows.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("history-closed-rows: skipping (run `bunx playwright install chromium`)");
    describe.skip("history closed rows", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "pages.history", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("Remove and Clear History delete Closed rows", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 640 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.history", { variant: "closed-remove-clear" })}`);
    // A cold dev server compiles the gallery on the first request; give it longer than the default.
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    // The play checks the behavior: one Closed row goes on Remove, the other on Clear History.
    expect(playFailures(report)).toEqual([]);
    expect((JSON.parse(report ?? "{}") as { steps?: unknown[] }).steps?.length, report).toBe(4);
  });
});
