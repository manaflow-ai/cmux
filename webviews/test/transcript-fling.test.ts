// A fast fling down a long chat keeps rows under the view (cx-j33s4). The frame pacing bench's
// fling (debug.ts startFling: 5000 rows, bottom to top in 3 s) left part of the view empty on
// 97-104 of 181 frames at the capped render rate: one frame there scrolls about as far as the
// transcript mounted ahead of the reader (App.tsx), so the next frame's view fell past it.
//
// Real WebKit from Playwright, at the 60 fps of the capped rate; CI fails the file when it
// cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-fling.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fling: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript fling", () => test("webkit", () => {}));
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
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Debug = {
    seedRows(count: number): Promise<unknown>;
    startFling(seconds: number, options: { wait: boolean }): Promise<Record<string, number>>;
    perfStats(): Record<string, unknown>;
  };

  test("the bench's 3 s fling over 5000 rows leaves the view blank on few frames", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
    await page.waitForFunction(() => "__debug" in window);
    const debug = <T>(call: (debug: Debug) => T | Promise<T>) =>
      page.evaluate(`(${call.toString()})(window.__debug)`) as Promise<T>;
    await debug((d) => d.seedRows(5000));
    // One fling warms the transcript's layout, as the bench's first fling does.
    await debug((d) => d.startFling(3, { wait: true }));
    const fling = await debug((d) => d.startFling(3, { wait: true }));
    const perf = (await debug((d) => d.perfStats())) as { frames: number; blank_frames: number };
    console.log(`transcript-fling: ${JSON.stringify({ fling, blank: perf.blank_frames, of: perf.frames })}`);
    expect(fling.frames).toBeGreaterThan(60);
    // A frame scrolls several viewports here; few of them may show an empty edge.
    expect(perf.blank_frames / perf.frames).toBeLessThanOrEqual(0.05);
    await page.close();
  });
});
