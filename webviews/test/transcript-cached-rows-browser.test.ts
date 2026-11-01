// Leo 2026-10-28, hq4738: already painted rows appear on the first frame back, without entrance.
// Same WebKit engine, 9000 source rows / 3000 turns and real transcript as the upward anchor trace.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-cached-rows-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
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

  test("a prefetched row mounted before intersection does not fade again after reattachment", async () => {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      await page.evaluate(`window.__debug.seedRows(9000)`);
      await page.waitForFunction(
        () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9000,
      );
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1e9, bubbles: true }));
        scroller.scrollTop = 600;
        for (let frame = 0; frame < 24; frame++) await window.cmuxPaintFrame();
      });
      const showOlder = async (shown: boolean) => {
        await page.evaluate(
          (shown) => (window as unknown as { __showOlder(shown: boolean): void }).__showOlder(shown),
          shown,
        );
        await page.evaluate(async () => {
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
        });
      };
      await showOlder(true);
      const prefetched = page.locator('[data-row-id="prefetched-older"]');
      expect(await prefetched.count()).toBe(1);
      // First render happened outside the view. Its fade starts now, never on a later intersection.
      expect(
        await prefetched.evaluate(
          (row) =>
            row.getBoundingClientRect().bottom <= document.querySelector(".acpmux-scroll")!.getBoundingClientRect().top,
        ),
      ).toBe(true);
      expect(await prefetched.getAttribute("data-older-shown")).toBe("true");
      await showOlder(false);
      expect(await prefetched.count()).toBe(0);
      await showOlder(true);
      expect(await prefetched.count()).toBe(1);
      expect(await prefetched.evaluate((row) => row.classList.contains("acpmux-row--older"))).toBe(false);
      expect(await prefetched.evaluate((row) => getComputedStyle(row).opacity)).toBe("1");
    } finally {
      await page.close();
    }
  });

  // Leo 2026-10-31: "WE DON'T NEED A FADE IN ANIMATION UNLESS IT'S THE WORST CASE". A page that lands
  // well above the reader, as prefetching makes the normal case, draws in place with no fade.
  test("an older page that lands ahead of the reader draws in place without a fade", async () => {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      await page.evaluate(`window.__debug.seedRows(9000)`);
      await page.waitForFunction(
        () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9000,
      );
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1e9, bubbles: true }));
        // Ten viewports below the first loaded row: the page arrives long before the reader gets there.
        scroller.scrollTop = 7000;
        for (let frame = 0; frame < 24; frame++) await window.cmuxPaintFrame();
      });
      await page.evaluate(async () => {
        (window as unknown as { __showOlder(shown: boolean): void }).__showOlder(true);
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = 0;
        for (let frame = 0; frame < 24; frame++) await window.cmuxPaintFrame();
      });
      const prefetched = page.locator('[data-row-id="prefetched-older"]');
      expect(await prefetched.count()).toBe(1);
      expect(await prefetched.evaluate((row) => row.classList.contains("acpmux-row--older"))).toBe(false);
      expect(await prefetched.getAttribute("data-older-shown")).toBeNull();
      expect(await prefetched.evaluate((row) => getComputedStyle(row).opacity)).toBe("1");
    } finally {
      await page.close();
    }
  });

  for (const way of ["jump", "revisit"] as const)
    test(`${way}: cached rows paint immediately at the target`, async () => {
      const { port } = vite.httpServer!.address() as { port: number };
      const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
      try {
        await installPaintedFrames(page);
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
        await page.waitForFunction(() => "__debug" in window);
        const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
        expect(seeded.rows).toBe(9000);
        await page.waitForFunction(
          () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9000,
        );
        const result = await page.evaluate(async (way) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const seen = new Set<string>();
          const samples: {
            phase: string;
            paint: number;
            top: number;
            target: boolean;
            blank: boolean;
            entering: string[];
          }[] = [];
          const end = () => scroller.scrollHeight - scroller.clientHeight;
          let phase = "prime";
          let frames = 0;
          let targetFrames = 0;
          let started = 0;
          let revisit = false;
          let targetLatency: number | null = null;
          let targetPaintLatency: number | null = null;
          await new Promise<void>((resolve) => {
            window.cmuxAfterPaint(
              (paint) => {
                const view = scroller.getBoundingClientRect();
                const visible = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter((row) => {
                  const box = row.getBoundingClientRect();
                  return box.height > 0 && box.bottom > view.top && box.top < view.bottom;
                });
                const entering = visible
                  .filter(
                    (row) => seen.has(row.dataset.rowId!) && row.matches(".acpmux-row--enter, .acpmux-row--older"),
                  )
                  .map((row) => row.dataset.rowId!);
                const blank =
                  visible.length === 0 ||
                  visible.some((row) => {
                    const style = getComputedStyle(row);
                    return Number(style.opacity) < 1 || !row.textContent?.trim();
                  });
                if (phase === "return") {
                  const target = Math.abs(scroller.scrollTop - end()) < 1;
                  samples.push({ phase, paint, top: scroller.scrollTop, target, blank, entering });
                  if (target) {
                    targetLatency ??= paint - started;
                    if (!blank) targetPaintLatency ??= paint - started;
                    targetFrames += 1;
                  }
                }
                for (const row of visible) seen.add(row.dataset.rowId!);
                frames += 1;
                // A revisit's scroll comes between frames, as input does: the page hears it in the
                // next frame's scroll steps, before that frame paints. Written in a frame's own
                // callbacks, after its scroll steps, it painted that frame at the new offset before
                // any page could know of it.
                if (revisit) {
                  revisit = false;
                  scroller.scrollTop = end();
                }
                if (targetFrames >= 12 || frames >= 180) {
                  resolve();
                  return false;
                }
              },
              (paint) => {
                // At least, not exactly: a frame's read can land after the next frame's callbacks
                // on a busy runner, and an exact count passed unseen left the run in its first phase
                // with no samples (frames 0, run 40753431130).
                if (frames >= 8 && phase === "prime") {
                  phase = "away";
                  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -50000, bubbles: true }));
                  scroller.scrollTop = Math.max(0, end() - 50000);
                }
                if (frames >= 32 && phase === "away") {
                  phase = "return";
                  started = paint;
                  if (way === "jump") document.querySelector<HTMLButtonElement>(".acpmux-jump-latest")!.click();
                  else revisit = true;
                }
              },
            );
          });
          return {
            frames: samples.length,
            blankFrames: samples.filter((sample) => sample.blank).length,
            targetBlankFrames: samples.filter((sample) => sample.target && sample.blank).length,
            cacheHitEntranceFrames: samples.filter((sample) => sample.entering.length > 0).length,
            targetFrames,
            targetLatency,
            targetPaintLatency,
            samples,
          };
        }, way);
        console.log(
          `transcript-cached-rows: ${JSON.stringify({ way, sourceRows: seeded.rows, turns: 3000, ...result })}`,
        );
        expect(result.targetFrames).toBeGreaterThanOrEqual(12);
        expect(result.blankFrames).toBe(0);
        expect(result.cacheHitEntranceFrames).toBe(0);
      } finally {
        await page.close();
      }
    });
});
