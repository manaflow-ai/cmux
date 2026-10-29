// The transcript's scroll thumb is seen to fade when it hides, not vanish (Leo 2026-10-29: "i also
// feel like the scroll thumb should fade instead of disappearing instantly"). Under the scroller
// fade (scrollers.ts SCROLLER_FADE_ATTRIBUTE), the thumb's ink after the scroll mark clears, read on
// each painted frame with the pane's own durations: it holds more than half its ink for a good
// part of the fade (an eased-out 180 ms fade was under half in about 50 ms, a blink), and it is gone
// once the fade's time has run.
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-scroller-fade-out.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-scroller-fade-out: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript scroller fade out", () => test("webkit", () => {}));
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

  test("the thumb fades out over frames a reader can see", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate(`window.__debug.seedRows(300)`);
    const samples = (await page.evaluate(async () => {
      document.documentElement.setAttribute("data-cmux-scroller-fade", "");
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const ink = () => {
        const inline = scroller.style.getPropertyValue("--cmux-shown-scroller-ink");
        if (inline) return parseFloat(inline);
        return scroller.hasAttribute("data-cmux-scrolling") ? 38 : 0;
      };
      // Scrolling: the thumb has its full ink (the fade in runs first).
      scroller.setAttribute("data-cmux-scrolling", "");
      for (let frame = 0; frame < 30; frame += 1) await window.cmuxPaintFrame();
      // The mark clears, as it does SCROLLING_HIDE_MS after the last scroll step.
      const out: { ms: number; ink: number }[] = [];
      let start = 0;
      await window.cmuxPaintFrame(() => {
        scroller.removeAttribute("data-cmux-scrolling");
        start = performance.now();
      });
      for (let frame = 0; frame < 60; frame += 1) {
        const at = await window.cmuxPaintFrame();
        out.push({ ms: Math.round(at - start), ink: Math.round(ink() * 10) / 10 });
      }
      return out;
    })) as { ms: number; ink: number }[];
    await page.close();
    const half = samples.find((sample) => sample.ink < 19);
    console.log(`transcript-scroller-fade-out: ${JSON.stringify({ halfAt: half?.ms, samples: samples.slice(0, 20) })}`);
    // More than half the ink for at least 100 ms of the fade.
    expect(half?.ms ?? Infinity).toBeGreaterThanOrEqual(100);
    // Several painted frames part-way, and none of the thumb left at the end.
    expect(samples.filter((sample) => sample.ink > 3 && sample.ink < 35).length).toBeGreaterThanOrEqual(4);
    expect(samples.at(-1)!.ink).toBe(0);
  });

  // The host's motion settings set the duration (ui.animationSpeed, Reduce Motion, animations off):
  // with no motion the thumb hides in the frame its scroll mark clears.
  test("with animations off the thumb hides at once", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate(`window.__debug.seedRows(300)`);
    const inks = (await page.evaluate(async () => {
      document.documentElement.setAttribute("data-cmux-scroller-fade", "");
      document.documentElement.style.setProperty("--agent-motion-move", "0ms");
      document.documentElement.style.setProperty("--agent-motion-in", "0ms");
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.setAttribute("data-cmux-scrolling", "");
      for (let frame = 0; frame < 5; frame += 1) await window.cmuxPaintFrame();
      await window.cmuxPaintFrame(() => scroller.removeAttribute("data-cmux-scrolling"));
      const out: string[] = [];
      for (let frame = 0; frame < 3; frame += 1) {
        await window.cmuxPaintFrame();
        out.push(scroller.style.getPropertyValue("--cmux-shown-scroller-ink"));
      }
      return out;
    })) as string[];
    await page.close();
    // No inline ink: the stylesheet's resting value (none) applies from the first frame.
    expect(inks).toEqual(["", "", ""]);
  });
});
