// window.cmuxAfterPaint promises a read of what a frame painted (support/paintedFrames.ts). Its read
// runs as a task after the frame, and the browser runs queued input first: while keys come in
// fast, a read could land after the next key had changed the page, and lay out a state no frame
// painted. agent-pane-scrollbar-full-height read the composer's card a line taller than the
// transcript's lift that frame painted (the ResizeObserver that lifts the rows runs in the next
// frame), and failed on a 4px jump that was never on screen (scroll-jitter, 2026-10-21).
//
// Real Chromium and WebKit with real key events. Every read must see the page as its frame did,
// and every frame is read. The test counts keys as a page's handler would, from the document.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/painted-frames.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("painted-frames.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`painted-frames: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("painted frames", () => test("browsers", () => {}));
    return;
  }
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  test.each(engines.map(([name]) => name))("%s: a read never sees a key that came after its frame", async (name) => {
    const page = await browsers.get(name)!.newPage();
    // Installed before setContent, as most tests do: document.open drops the window's listeners.
    await installPaintedFrames(page);
    await page.setContent("<textarea></textarea>");
    await page.evaluate(() => {
      const w = window as unknown as {
        __keys: number;
        __frames: number;
        __reads: [number, number][];
        __stop: () => void;
      };
      w.__keys = 0;
      w.__frames = 0;
      w.__reads = [];
      // On the document, as a page's own handlers are: the window's capture runs before it.
      document.addEventListener("keydown", () => (w.__keys += 1), true);
      let atFrame = 0;
      w.__stop = window.cmuxAfterPaint(
        () => void w.__reads.push([atFrame, w.__keys]),
        () => {
          w.__frames += 1;
          atFrame = w.__keys;
        },
      );
    });
    await page.locator("textarea").click();
    // Keys as fast as the driver sends them, so input queues up behind each frame.
    for (let round = 0; round < 4; round++) await page.keyboard.type("the quick brown fox jumps over the lazy dog ");
    await page.evaluate(() => window.cmuxPaintFrame());
    const { reads, frames } = await page.evaluate(() => {
      const w = window as unknown as { __frames: number; __reads: [number, number][]; __stop: () => void };
      w.__stop();
      return { reads: w.__reads, frames: w.__frames };
    });
    await page.close();
    // Every frame is read, input or not (the last two reads can still be on their way: under load
    // the next frame can start before a read's task runs).
    expect(reads.length).toBeGreaterThanOrEqual(frames - 2);
    // Keys counted by the read that its frame had not seen.
    expect(reads.filter(([atFrame, atRead]) => atRead !== atFrame)).toEqual([]);
  });
});
