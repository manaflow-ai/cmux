// A composer location menu keeps the side it chose when it opened (cx-ncc.53). The gallery's
// `agent-pane.composer-context-side` play opens the folder popover where its full list does not fit
// above the chip, filters it until it would, and fails if the popup changes side; this runs the
// play in Chromium and checks it passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
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
    // Warm the gallery stage once before the measured page, as composer-mention.test.ts does: the
    // first load can trigger Vite's dependency optimizer and reload its context mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-context-side", {
      browser,
      params: { variant: "filter-keeps-side" },
    });
  });

  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-context-side", { variant })}`;

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the folder popover stays on the side it opened on while a filter shrinks it", async () => {
    const page = await browser!.newPage({ viewport: { width: 620, height: 560 } });
    await page.goto(url("filter-keeps-side"));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    // The play throws when the side or placement is wrong.
    expect(playFailures(result.report)).toEqual([]);
  });

  test("the folder popover prefers below when both sides fit", async () => {
    const page = await browser!.newPage({ viewport: { width: 620, height: 900 } });
    await page.goto(url("below-when-room"));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    expect(playFailures(result.report)).toEqual([]);
  });
});
