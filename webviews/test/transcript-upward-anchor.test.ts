// Leo 2026-10-28: upward scrolling has a "weird recalculation". Measure row movement after paint,
// subtracting only the distance the wheel requested, while cold rows above the view first measure.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-upward-anchor.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-upward-anchor: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript upward anchor", () => test("webkit", () => {}));
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
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("cold 3k-turn upward wheels preserve the visible row's position", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
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
        `transcript-upward-anchor: ${JSON.stringify({ sourceRows: seeded.rows, turns: seeded.rows / 3, shownRows, ...result })}`,
      );
      expect(result.cancelledWheels).toBe(0);
      expect(result.wheelPixels).toBeLessThan(-8_000);
      expect(result.frames).toBe(264);
      expect(result.compared).toBe(result.frames);
      expect(result.missingAnchors).toBe(0);
      expect(result.blankFrames).toBe(0);
      expect(result.blankBandFrames).toBe(0);
      expect(result.maxRowBoxGap).toBeLessThanOrEqual(1 / 64);
      expect(result.blankEdgeFrames).toBe(0);
      expect(result.maxViewportEdgeGap).toBeLessThanOrEqual(1 / 64);
      // DOM coordinates use fractional CSS pixels; allow only one 1/64 px layout quantum.
      expect(result.maxDrift).toBeLessThanOrEqual(1 / 64);
    } finally {
      await page.close();
    }
  });
  test.each(["top", "bottom"] as const)(
    "the painted oracle detects a blank band at the %s viewport edge",
    async (edge) => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      try {
        await installPaintedFrames(page);
        const top = edge === "top" ? 40 : -40;
        // Middle transcript rows remain adjacent; only one viewport edge is uncovered. These
        // negative oracle fixtures make an adjacency-only check fail to detect the missing paint.
        await page.setContent(`
        <div class="acpmux-scroll" style="position:relative;height:200px;overflow:hidden">
          <article class="acpmux-row" data-row-id="a" aria-posinset="2" aria-setsize="4"
            style="position:absolute;top:${top}px;height:100px;width:100%">A</article>
          <article class="acpmux-row" data-row-id="b" aria-posinset="3" aria-setsize="4"
            style="position:absolute;top:${top + 100}px;height:100px;width:100%">B</article>
        </div>`);
        const result = await page.evaluate(traceUpwardAnchors, { steps: [0], restFrames: 0 });
        expect(result.frames).toBe(1);
        expect(result.compared).toBe(1);
        expect(result.maxRowBoxGap).toBe(0);
        expect(result.blankEdgeFrames).toBe(1);
        expect(result.maxViewportEdgeGap).toBe(40);
        expect(result.samples[0]![edge === "top" ? "topEdgeGap" : "bottomEdgeGap"]).toBe(40);
      } finally {
        await page.close();
      }
    },
  );

  test("received card folds preserve painted row-box adjacency while streaming", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
      expect(seeded.rows).toBe(9000);
      await page.evaluate(() => (window as unknown as { __seedFoldStream(): void }).__seedFoldStream());
      const card = page.locator('[data-row-id="gap-incoming"]');
      await card.waitFor();
      await card.evaluate((node) => node.scrollIntoView({ block: "start" }));
      const result = await page.evaluate(traceUpwardAnchors, {
        steps: Array.from({ length: 112 }, () => 0),
        foldStream: true,
      });
      console.log(`transcript-fold-stream: ${JSON.stringify({ sourceRows: seeded.rows, turns: 3000, ...result })}`);
      expect(result.frames).toBe(136);
      expect(result.compared).toBe(result.frames);
      expect(result.missingAnchors).toBe(0);
      expect(result.maxDrift).toBeLessThanOrEqual(1 / 64);
      expect(result.blankFrames).toBe(0);
      expect(result.blankBandFrames).toBe(0);
      expect(result.maxRowBoxGap).toBeLessThanOrEqual(1 / 64);
      expect(result.blankEdgeFrames).toBe(0);
      expect(result.maxViewportEdgeGap).toBeLessThanOrEqual(1 / 64);
    } finally {
      await page.close();
    }
  });
});
