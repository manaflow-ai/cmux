// Leo 2026-10-28: upward scrolling has a "weird recalculation". Measure row movement after paint,
// subtracting only the distance the wheel requested, while cold rows above the view first measure.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { calibrateScrollReadback, traceUpwardAnchors } from "./support/upwardAnchorTrace";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-upward-anchor.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engineName = process.env.CMUX_SCROLL_ENGINE === "chromium" ? "chromium" : "webkit";
  const engine = engineName === "chromium" ? chromium : webkit;
  try {
    await (await engine.launch({ headless: true })).close();
  } catch {
    console.warn(`transcript-upward-anchor: skipping (run 'bunx playwright install ${engineName}')`);
    describe.skip("transcript upward anchor", () => test(engineName, () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-fling.html");
    browser = await engine.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("cold 3k-turn upward wheels preserve the visible row's position", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const captureDir = process.env.CMUX_SCROLL_CAPTURE_DIR;
    const page = await browser!.newPage({
      viewport: { width: 900, height: 700 },
      ...(captureDir ? { recordVideo: { dir: captureDir, size: { width: 900, height: 700 } } } : {}),
    });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      const calibration = await page.evaluate(calibrateScrollReadback);
      // Three source rows per synthetic turn: user, assistant and summary.
      const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
      expect(seeded.rows).toBe(9_000);
      await page.waitForFunction(
        () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9_000,
      );
      const shownRows = await page.evaluate(() =>
        Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")),
      );
      // No warm fling: rows encountered above the viewport must still have estimated heights.
      const steps = Array.from({ length: 240 }, (_, frame) => -[18.25, 42.5, 27.75, 56.125][frame % 4]!);
      const result = await page.evaluate(traceUpwardAnchors, { steps });
      // Preserve the complete row-id/y trace in the hosted log, on both a pass and a failure.
      console.log(
        `transcript-upward-anchor: ${JSON.stringify({ engine: engineName, calibration, sourceRows: seeded.rows, turns: seeded.rows / 3, shownRows, ...result })}`,
      );
      expect(result.cancelledWheels).toBe(0);
      expect(result.wheelPixels).toBeLessThan(-8_000);
      expect(result.compared).toBe(result.frames);
      expect(result.blankFrames).toBe(0);
      // WebKit keeps scrollTop in whole CSS pixels (the trace's applied wheel distances are whole)
      // while rows lay out on quarter pixels, and the anchor correction leaves a residual of at most
      // half a pixel rather than fight that rounding. Before this repair the same trace drifted 56.5px.
      expect(result.maxDrift).toBeLessThanOrEqual(0.5);
    } finally {
      await page.close();
      const video = page.video();
      if (captureDir && video) {
        const data = Buffer.from(await Bun.file(await video.path()).arrayBuffer()).toString("base64");
        for (let at = 0; at < data.length; at += 4096)
          console.log(`ANCHOR_VIDEO=${JSON.stringify({ engine: engineName, at, data: data.slice(at, at + 4096) })}`);
      }
    }
  });
});
