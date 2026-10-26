// l10n-allow-file: deterministic transcript fixture text.
// Real Chromium regression for the rail's animated jump: manual input over the rail must cancel the
// in-flight motion immediately and keep follow/landing code from starting another move for one second.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("scroll-intent-rail.test.ts", async () => {
  setDefaultTimeout(120_000);
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
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("manual pointer input over the rail stops a jump before it drifts toward its target", async () => {
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    const rows = Array.from({ length: 36 }, (_, index) => [
      { id: `intent-${index}-user`, kind: "user", text: `Prompt ${index}`, version: 1, at: index },
      {
        id: `intent-${index}-answer`,
        kind: "assistant",
        text: "A long answer keeps the transcript tall enough to animate across several frames.",
        version: 1,
        at: index,
      },
      { id: `intent-${index}-end`, kind: "turnSummary", status: "completed", durationMs: 1, version: 1, at: index },
    ]).flat();
    await page.evaluate((shown) => (window as any).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__tick");
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      for (let frame = 0; frame < 4; frame += 1) await window.cmuxPaintFrame();
    });
    await page.evaluate(() => (window as any).__startRailJump());
    await page.evaluate(async () => {
      for (let frame = 0; frame < 2; frame += 1) await window.cmuxPaintFrame();
    });
    const start = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
    await page.evaluate(() => {
      const rail = document.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
      const frames: number[] = [];
      (window as any).__railIntentFrames = frames;
      (window as any).__stopRailIntentFrames = window.cmuxAfterPaint(() => {
        frames.push(document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
        return frames.length < 90;
      });
      rail.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerId: 1 }));
      // A follow/landing correction arriving in the same turn must be refused while the manual
      // intent hold is active; the current base starts another animated move here.
      (window as any).__startRailJump();
    });
    await page.evaluate(async () => {
      for (let frame = 0; frame < 75; frame += 1) await window.cmuxPaintFrame();
    });
    const frames = await page.evaluate(() => {
      (window as any).__stopRailIntentFrames?.();
      return (window as any).__railIntentFrames as number[];
    });
    await page.close();
    expect(start).toBeGreaterThan(0);
    expect(frames.slice(1).filter((top) => top < start - 1)).toEqual([]);
  });
});
