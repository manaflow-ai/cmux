// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// A fold ride lands on input (conversation/foldRide.ts `land`): the full-height thread map aims a
// click by the transcript's layout (ScrollMap.tsx `seek`, from `layout.totalHeight`), which mid-ride
// is still the one placed before the fold. Real Chromium opens "Ran 100 commands"
// (ToolGroupSize.gallery.ts) and, while it still opens, clicks the map's track: the view goes where
// the rows as shown put that point, not short by the fold's growth (review of #39917 at e357b4a0:
// "lands 800px short of the new bottom").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { scrollTopAt } from "../src/agent-session/acpmux/threadMinimap/mapGeometry";

await requireBrowserLane("fold-ride-map-scrub-browser.test.ts", async () => {
  const ENTRY = "agent-pane.tool-group-size";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("fold-ride-map-scrub-browser: skipping (run `bunx playwright install chromium`)");
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "n100" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ROW = '[data-row-id="tool-group-size-run"]';
  const GROUP = `${ROW} button[data-tool-group]`;
  const MAP = ".acpmux-scrollmap";

  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 8; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}:${document.querySelectorAll(".cv-step").length}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      localStorage.clear();
      (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
        "thread-minimap-layout": "full",
        // The fold ride concerns a run that grows the transcript; box runs scroll internally.
        "run-scroll": "inline",
      };
    });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "n100" })}`);
    await page.locator(GROUP).waitFor();
    await page.locator(MAP).waitFor();
    await settled(page);
    return page;
  }

  test("a click on the map while a run opens aims by the rows as they show", async () => {
    const page = await open();
    // Scrolled up from the end, so the run opens away from the bottom and its rows ride.
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1, bubbles: true }));
      scroller.scrollTop = 0;
    });
    await settled(page);
    await page.locator(GROUP).click();
    await page.waitForFunction(
      () => [...document.querySelectorAll<HTMLElement>(".acpmux-row")].some((row) => row.style.translate),
      undefined,
      { timeout: 10_000 },
    );
    // One task: the content height as the rows show it, then a click on the track at 3/4 of the rail
    // (one seek), then where the view went, before the fold's next frame.
    const seen = await page.evaluate((map) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const rail = document.querySelector<HTMLElement>(map)!;
      const spacer = document.querySelector<HTMLElement>(".acpmux-spacer")!;
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")];
      const ride = Math.max(...rows.map((row) => parseFloat(row.style.translate.split(" ")[1] ?? "") || 0));
      const placed = parseFloat(spacer.style.height);
      const box = rail.getBoundingClientRect();
      const y = box.height * 0.75;
      const at = {
        bubbles: true,
        clientX: box.left + box.width / 2,
        clientY: box.top + y,
        pointerId: 1,
        isPrimary: true,
      };
      rail.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1 }));
      rail.dispatchEvent(new PointerEvent("pointerup", at));
      return {
        y,
        railHeight: box.height,
        viewport: scroller.clientHeight,
        placed,
        ride,
        top: scroller.scrollTop,
        riding: rows.some((row) => row.style.translate),
      };
    }, MAP);
    await page.close();
    if (process.env.FOLD_RIDE_DEBUG === "1") console.log(JSON.stringify(seen));
    expect(seen.ride).toBeGreaterThan(100);
    expect(seen.riding).toBe(false);
    // Aimed by the shown content (the placed height plus the ride), not the placed one.
    const shown = scrollTopAt(seen.y, seen.railHeight, seen.placed + seen.ride, seen.viewport);
    const stale = scrollTopAt(seen.y, seen.railHeight, seen.placed, seen.viewport);
    expect(Math.abs(seen.top - shown)).toBeLessThan(Math.abs(seen.top - stale));
    expect(Math.abs(seen.top - shown)).toBeLessThan(40);
  });
});
