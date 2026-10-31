// l10n-allow-file: fixture prompts and replies, not shipped UI.
// A fast wheel over the session rail keeps every row in its view drawn on every painted frame
// (Leo, 2026-10-31: "if i scroll too fast in the left scroll rail it can flicker and disapper at the
// edges"). The rail draws only the rows near its view (tickWindow.ts) and moves that window from its
// list's scroll event. The window used to follow a frame late and only 12 rows past each edge, so a
// wheel step longer than 120 px showed blank spacer rows at the edge the list scrolled toward for a
// frame, then the ticks popped in: the flicker at the edges.
//
// Each frame's drawn rows are read in its frame callbacks (they are what that frame paints) and the
// list's offset after the frame has painted (support/paintedFrames.ts); a row in the list's view with
// no tick in the frame is a blank the reader saw. Locally:
// CI=1 CMUX_BROWSER_TESTS=1 bun test test/thread-rail-fast-scroll-edges.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-fast-scroll-edges.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`thread-rail-fast-scroll-edges: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("rail fast scroll", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    current = browsers.values().next().value;
    // 3,000 prompts, as the rail latency cases (test/latency/actions.ts).
    pane = await papercutPane(() => current!, { turns: 3000, running: false });
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  type Frame = { top: number; height: number; missing: number[]; entering: number };
  /// Starts recording every painted frame of the rail's list; `stop` returns the frames.
  const record = (page: Page) =>
    page.evaluate(() => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      const frames: Frame[] = [];
      let drawn = new Set<number>();
      let entering = 0;
      const stop = window.cmuxAfterPaint(
        () => {
          const top = list.scrollTop;
          const height = list.clientHeight;
          const count = Number(list.querySelector("li[aria-setsize]")?.getAttribute("aria-setsize") ?? 0);
          const missing: number[] = [];
          // Every row the view shows at least half of.
          const first = Math.ceil(top / 10 - 0.5);
          const last = Math.min(count, Math.floor((top + height) / 10 + 0.5));
          for (let row = Math.max(0, first); row < last; row++) if (!drawn.has(row)) missing.push(row);
          frames.push({ top, height, missing, entering });
        },
        () => {
          // What this frame paints: the frame's callbacks run after its input and scroll events.
          drawn = new Set([...list.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => Number(tick.dataset.tick)));
          entering = list.querySelectorAll("[data-entering]").length;
        },
      );
      (window as unknown as { __railFrames: () => Frame[] }).__railFrames = () => {
        stop();
        return frames;
      };
    });
  const frames = (page: Page) =>
    page.evaluate(() => (window as unknown as { __railFrames: () => Frame[] }).__railFrames());

  for (const name of ["chromium", "webkit"]) {
    test(`${name}: a fast fling to both ends draws every row in the rail's view on every frame`, async () => {
      const browser = browsers.get(name);
      if (!browser) return;
      current = browser;
      const page = await pane!.open({ width: 1280, height: 900 });
      try {
        await installPaintedFrames(page);
        const list = page.locator(".acpmux-minimap__list[data-rail-scrolls]");
        await list.waitFor({ timeout: 20_000 });
        // The ticks' own entrance is over before the fling (it is not what this measures).
        await page.evaluate(() =>
          Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
        );
        const box = (await list.boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await record(page);
        // A flick of a mouse wheel with acceleration: long steps, then a momentum tail that decays,
        // down to the end and back up to the start.
        for (const sign of [-1, 1, -1]) {
          for (let step = 0; step < 24; step++) await page.mouse.wheel(0, sign * 900);
          for (let delta = 900; delta > 4; delta *= 0.82) await page.mouse.wheel(0, sign * delta);
        }
        for (let step = 0; step < 40; step++) await page.mouse.wheel(0, 1200);
        for (let step = 0; step < 40; step++) await page.mouse.wheel(0, -1200);
        await page.evaluate(() => window.cmuxPaintFrame());
        await page.evaluate(() => window.cmuxPaintFrame());
        const seen = await frames(page);
        const moved = seen.filter((frame, index) => index > 0 && frame.top !== seen[index - 1]!.top);
        // The fling moved the list (it reached both of its ends on the way).
        expect(moved.length).toBeGreaterThan(10);
        expect(Math.max(...seen.map((frame) => frame.top))).toBeGreaterThan(20_000);
        expect(Math.min(...seen.map((frame) => frame.top))).toBe(0);
        const blank = seen.filter((frame) => frame.missing.length > 0);
        expect(
          blank.slice(0, 3).map((frame) => ({ top: frame.top, height: frame.height, missing: frame.missing.length, first: frame.missing[0] })),
        ).toEqual([]);
        // No row the fling brings into view replays the entrance (#26635): it would start at opacity 0.
        expect(Math.max(...seen.map((frame) => frame.entering))).toBe(0);
      } finally {
        await page.close();
      }
    });
  }
});
