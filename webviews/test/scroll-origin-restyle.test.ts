// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A streamed token restyles the rows it changed, not every mounted row (Leo, 2026-11-16: "but
// typing under load is not good enough").
//
// Each time a streaming reply settles to the bottom, the transcript keeps its rows on whole pixels by
// writing the sub-pixel remainder of its scroll offset (conversation/scrollCoordinates.ts
// `retainScrollOrigin`), which moves the thread. Written on the scroller as an unregistered, so
// inherited, custom property (`--acpmux-scroll-origin`, read by the thread's `top`), every write
// restyled every element under the scroller: 1,972 elements on this 1,480-element page, 92-96% of
// what a stream restyles, which landed between typed keys as ~12 ms of style per key (a Chromium trace
// with invalidation tracking, bench/composer-typing.bench.ts --modes stream). A custom property on the
// thread still restyled 276 (Chromium restyles an element's children for one); the thread's own
// `margin-top` restyles a handful.
//
// The real pane (`?mock`), a light 700-turn chat opened at its end; one write and one clear through
// the transcript's own writer, traced with Chromium's own UpdateLayoutTree counts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("scroll-origin-restyle.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Elements Chromium restyled (UpdateLayoutTree elementCount, summed) while `run` ran. */
  async function restyled(page: Page, run: () => Promise<unknown>): Promise<number> {
    await page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
    await browser!.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] });
    await run();
    const trace = JSON.parse((await browser!.stopTracing()).toString()) as {
      traceEvents: { name: string; ph: string; args?: any }[];
    };
    let elements = 0;
    for (const event of trace.traceEvents) {
      if (event.name !== "UpdateLayoutTree" || (event.ph !== "X" && event.ph !== "E")) continue;
      elements += Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
    }
    return elements;
  }

  test("a write of the scroll origin restyles the thread, not every mounted row", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(700, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-scroll .acpmux-row").length > 5);
    const mounted = await page.evaluate(() => document.querySelectorAll(".acpmux-scroll *").length);

    // One write and one clear through the transcript's own writer (the page's module instance), each
    // read back as the transcript does: it reads scrollTop at once.
    await page.evaluate(() => import("/conversation/scrollCoordinates.ts" as string));
    const place = (write: boolean) =>
      page.evaluate(async (write) => {
        const coordinates = await import("/conversation/scrollCoordinates.ts" as string);
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const thread = scroller.querySelector<HTMLElement>(".acpmux-thread")!;
        const before = thread.getBoundingClientRect().top;
        // A logical top half a pixel above the physical offset leaves a remainder of 0.5px.
        if (write) coordinates.retainScrollOrigin(scroller, scroller.scrollTop - 0.5);
        else coordinates.clearScrollOrigin(scroller);
        void scroller.scrollTop;
        const moved = thread.getBoundingClientRect().top - before;
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        return moved;
      }, write);
    let moved = 0;
    const write = await restyled(page, async () => {
      moved = await place(true);
    });
    let back = 0;
    const clear = await restyled(page, async () => {
      back = await place(false);
    });
    await page.close();
    console.log(`SCROLL-ORIGIN-RESTYLE ${JSON.stringify({ mounted, write, clear, moved, back })}`);

    expect(mounted).toBeGreaterThan(500);
    // The thread still takes the origin: its rows move by it, and back.
    expect(moved).toBeCloseTo(0.5, 1);
    expect(back).toBeCloseTo(-0.5, 1);
    // A write restyles a handful of elements, not the mounted rows: before, it restyled every element
    // under the scroller.
    expect(write, "elements restyled by one scroll-origin write").toBeLessThan(20);
    expect(clear, "elements restyled by clearing the scroll origin").toBeLessThan(20);
  });
});
