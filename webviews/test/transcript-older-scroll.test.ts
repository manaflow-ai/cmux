// Scrolling up a long chat asks for older history well before the top, so the view never stops
// there waiting for a page (Leo 2026-10-29: "scrolling up when it paginates and loads... didnt we
// previously have it pretty fast? why is it sometimes blocking me from scrolling up further?").
// The reader scrolls up with real wheel input, one step a frame, while each older page takes
// 400 ms to land (a read from acpmux).
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-older-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-older-scroll: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript older scroll", () => test("webkit", () => {}));
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
    await warmViteServer(vite, "/test/browser/transcript-older-scroll.html");
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// How far into the chat the view is: its offset less the height older pages added above the
  /// first row it started on. A page that lands moves the offset and the content alike, so this moves
  /// only with the reader's scroll (and with a correction that loses or adds to it).
  const place = () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const older = (window as unknown as { __older: { loaded(): number; total: number } }).__older;
    return {
      scrollTop: scroller.scrollTop,
      scrollHeight: scroller.scrollHeight,
      more: older.loaded() < older.total,
    };
  };

  /// Scrolls up `frames` wheel steps of `step` px, one a frame, and measures how far the view went
  /// into the chat against how far the wheel asked. WebKit applies a wheel step on its scrolling
  /// thread and may report it to the page a frame later, so the travel is read once the scroll has
  /// settled, never step by step.
  const scrollUp = async (page: Page, step: number, frames: number) => {
    let topFrames = 0;
    let wheeled = 0;
    await page.mouse.move(450, 350);
    const start = (await page.evaluate(place)) as ReturnType<typeof place>;
    for (let frame = 0; frame < frames; frame += 1) {
      const now = (await page.evaluate(place)) as ReturnType<typeof place>;
      if (now.more && now.scrollTop <= 1) topFrames += 1;
      if (!now.more && now.scrollTop <= 1) break;
      await page.mouse.wheel(0, -step);
      wheeled += step;
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    for (let frame = 0; frame < 20; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    const end = (await page.evaluate(place)) as ReturnType<typeof place>;
    const travel = start.scrollTop - end.scrollTop + (end.scrollHeight - start.scrollHeight);
    return { wheeled, travel: Math.round(travel), lost: Math.round(wheeled - travel), topFrames };
  };

  for (const step of [40, 100]) {
    test(`a ${step} px-a-frame scroll up asks for older pages well before the top`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await installPaintedFrames(page);
      await page.goto(
        `http://127.0.0.1:${port}/test/browser/transcript-older-scroll.html${process.env.OLDER_SCROLL_ALL ? "?all" : ""}`,
      );
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 5);
      // Notches glide over several frames; this measures a precise trackpad's step-a-frame scroll.
      await page.evaluate(() => (document.documentElement.dataset.wheelGlide = "off"));
      for (let frame = 0; frame < 10; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
      const frames = 300;
      const result = await scrollUp(page, step, frames);
      const asks = await page.evaluate(() => {
        const older = (window as unknown as { __older: { asks: { at: number; top: number; landed?: number }[] } })
          .__older;
        return older.asks.map((ask) => ({ top: Math.round(ask.top), ms: Math.round((ask.landed ?? NaN) - ask.at) }));
      });
      console.log(
        `transcript-older-scroll ${step}px: ${JSON.stringify({ ...result, asks: asks.length, first: asks.slice(0, 4) })}`,
      );
      if (!process.env.OLDER_SCROLL_ALL) expect(asks.length).toBeGreaterThan(1);
      // Each page is asked for at least four viewports above the view (two left a flick a fraction
      // of a second before the top), and the view never sat at the top waiting. The travel against
      // the wheel is logged: headless WebKit drops some of a fast wheel's distance with no paging
      // at all (OLDER_SCROLL_ALL), so it is not asserted.
      expect(Math.min(...asks.map((ask) => ask.top))).toBeGreaterThanOrEqual(4 * 700);
      expect(result.topFrames).toBe(0);
      await page.close();
    });
  }
});
