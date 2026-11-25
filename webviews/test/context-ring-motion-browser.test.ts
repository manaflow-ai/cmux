// The composer's context ring eases to a new reading instead of jumping (Leo, 2026-11-07: "after a
// compaction, right? Then the context, like, goes from whatever amount percent it was on the
// circle, and then it goes back down. I feel like that should, like, play a cute little, like,
// eased animation that goes down"). In a real browser (test/browser/context-ring-motion.harness.tsx):
// - a compaction's drop (85% to 12%) and a turn's rise (40% to 55%) ease over about 600 ms, the arc
//   part-way at the midpoint, and a reading mid-way starts from what is drawn;
// - the percent beside the ring (the `percent` look) counts along with the arc;
// - opening a chat and switching chats show that chat's value at once, with nothing animating;
// - under Reduce Motion the new reading is drawn in one frame.
// On base the ring jumps: the first two fail there.
//
// Real Chromium (and WebKit where installed) from Playwright; CI fails the file when it cannot
// launch (requireBrowserLane). CONTEXT_RING_CAPTURE=DIR writes each state's 4x crop there.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("context-ring-motion-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/context-ring-motion.html");
    for (const [name, engine] of engines) {
      try {
        browsers.set(name, await engine.launch({ headless: true }));
      } catch {
        if (name === "chromium") throw new Error("Chromium did not launch (bunx playwright install chromium)");
        console.warn(`context-ring-motion: ${name} is not installed here, so only Chromium runs`);
      }
    }
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Reading = { chat?: string; used?: number; size?: number; motion?: string; look?: string };
  const SIZE = 200_000;
  const share = (percent: number) => (percent / 100) * SIZE;

  async function open(engine: string, options: { reducedMotion?: "reduce" } = {}): Promise<Page> {
    const browser = browsers.get(engine);
    if (!browser) throw new Error(`${engine} is not running`);
    const page = await browser.newPage({ viewport: { width: 240, height: 80 }, deviceScaleFactor: 4 });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    if (options.reducedMotion) await page.emulateMedia({ reducedMotion: options.reducedMotion });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/context-ring-motion.html`);
    await page.waitForFunction(() => typeof (window as unknown as { ring?: unknown }).ring === "function");
    expect(errors).toEqual([]);
    return page;
  }

  const render = (page: Page, reading: Reading) =>
    page.evaluate((reading) => (window as unknown as { ring(r: Reading): void }).ring(reading), reading);

  /** The share the arc draws now, from its dash (used length over the whole circle). */
  const drawn = (page: Page) =>
    page.evaluate(() => {
      const arc = document.querySelector<SVGCircleElement>(".acpmux-context-used");
      if (!arc) return 0;
      const dash = getComputedStyle(arc)
        .strokeDasharray.split(/[ ,]+/)
        .map((part) => Number.parseFloat(part))
        .filter(Number.isFinite);
      // Base: "C·f C"; head: "f 1" over a path length of 1.
      return dash.length >= 2 ? dash[0]! / dash[1]! : Number.NaN;
    });

  /** The ring's running motions: their total length, in ms. */
  const motions = (page: Page) =>
    page.evaluate(() =>
      document
        .getAnimations()
        .filter((animation) => animation.playState === "running")
        .filter((animation) => {
          const target = (animation.effect as KeyframeEffect | null)?.target;
          return target instanceof Element && target.closest(".acpmux-context") !== null;
        })
        .map((animation) => Number(animation.effect?.getComputedTiming().endTime ?? 0))
        // Reduce Motion's 0.01 ms transitions (shared/desktop.css) land in the next frame: not motion.
        .filter((length) => length >= 1),
    );

  /** Holds every motion at `ms` from its start. */
  const holdAt = (page: Page, ms: number) =>
    page.evaluate((ms) => {
      for (const animation of document.getAnimations()) {
        animation.pause();
        animation.currentTime = ms;
      }
    }, ms);

  const finish = (page: Page) =>
    page.evaluate(() => {
      for (const animation of document.getAnimations()) animation.finish();
    });

  /** The percent the caption shows now: its own text, or the counter's eased integer. */
  const caption = (page: Page) =>
    page.evaluate(() => {
      const element = document.querySelector<HTMLElement>(".acpmux-context-caption");
      if (!element) return undefined;
      const text = element.textContent?.trim();
      if (text) return Number.parseInt(text, 10);
      return Number.parseInt(getComputedStyle(element).getPropertyValue("--acpmux-ring-percent"), 10);
    });

  const capture = async (page: Page, name: string) => {
    const dir = process.env.CONTEXT_RING_CAPTURE;
    if (!dir) return;
    fs.mkdirSync(dir, { recursive: true });
    await page.screenshot({ path: path.join(dir, `${name}.png`), clip: { x: 0, y: 0, width: 120, height: 70 } });
  };

  for (const engine of ["chromium", "webkit"] as const)
    describe(engine, () => {
      const run = (name: string, body: () => Promise<void>) =>
        test(name, async () => {
          if (!browsers.has(engine)) return;
          await body();
        });

      for (const [from, to, what] of [
        [85, 12, "a compaction's drop"],
        [40, 55, "a turn's rise"],
      ] as const)
        run(`${what} (${from}% to ${to}%) eases over about 600 ms, part-way at the midpoint`, async () => {
          const page = await open(engine);
          try {
            await render(page, { chat: "a", used: share(from), size: SIZE });
            await finish(page);
            await render(page, { chat: "a", used: share(to), size: SIZE });
            // The frame of the change still draws the old reading, and one motion of about 600 ms runs.
            expect(await drawn(page)).toBeCloseTo(from / 100, 2);
            const running = await motions(page);
            expect(running.length).toBeGreaterThanOrEqual(1);
            for (const length of running) {
              expect(length).toBeGreaterThanOrEqual(500);
              expect(length).toBeLessThanOrEqual(700);
            }
            await holdAt(page, 300);
            const mid = await drawn(page);
            await capture(page, `${engine}-${from}-${to}-mid`);
            // Part-way, and past the halfway point of the travel: it eases out.
            const travelled = (mid - from / 100) / ((to - from) / 100);
            expect(travelled).toBeGreaterThan(0.5);
            expect(travelled).toBeLessThan(0.95);
            await finish(page);
            expect(await drawn(page)).toBeCloseTo(to / 100, 2);
            await capture(page, `${engine}-${from}-${to}-end`);
          } finally {
            await page.close();
          }
        });

      run("a reading mid-way starts from what is drawn, not from the last target", async () => {
        const page = await open(engine);
        try {
          await render(page, { chat: "a", used: share(85), size: SIZE });
          await render(page, { chat: "a", used: share(12), size: SIZE });
          await holdAt(page, 300);
          const mid = await drawn(page);
          await page.evaluate(() => {
            for (const animation of document.getAnimations()) animation.play();
          });
          await render(page, { chat: "a", used: share(30), size: SIZE });
          const start = await drawn(page);
          // Within a frame or two of where the arc was drawn, never back at 85% or a jump to 30%.
          expect(Math.abs(start - mid)).toBeLessThan(0.06);
          await finish(page);
          expect(await drawn(page)).toBeCloseTo(0.3, 2);
        } finally {
          await page.close();
        }
      });

      for (const motion of ["ease", "spring"])
        run(`the percent beside the ring counts with the arc (${motion})`, async () => {
          const page = await open(engine);
          try {
            await render(page, { chat: "a", used: share(85), size: SIZE, motion, look: "percent" });
            expect(await caption(page)).toBe(85);
            await render(page, { chat: "a", used: share(12), size: SIZE, motion, look: "percent" });
            await holdAt(page, 300);
            const percent = (await caption(page))!;
            await capture(page, `${engine}-percent-${motion}-mid`);
            expect(Math.abs(percent - (await drawn(page)) * 100)).toBeLessThanOrEqual(1);
            expect(percent).toBeGreaterThan(12);
            expect(percent).toBeLessThan(85);
            await finish(page);
            expect(await caption(page)).toBe(12);
          } finally {
            await page.close();
          }
        });

      run("opening a chat and switching chats draw that chat's reading at once", async () => {
        const page = await open(engine);
        try {
          // Mount, then the first report: no motion from an empty ring.
          await render(page, { chat: "a" });
          await render(page, { chat: "a", used: share(85), size: SIZE });
          expect(await motions(page)).toEqual([]);
          expect(await drawn(page)).toBeCloseTo(0.85, 2);
          // Another chat, at its own reading, then back.
          await render(page, { chat: "b", used: share(30), size: SIZE });
          expect(await motions(page)).toEqual([]);
          expect(await drawn(page)).toBeCloseTo(0.3, 2);
          await render(page, { chat: "a", used: share(85), size: SIZE });
          expect(await motions(page)).toEqual([]);
          expect(await drawn(page)).toBeCloseTo(0.85, 2);
          // A fresh page mounting straight at a reading.
          const fresh = await open(engine);
          try {
            await render(fresh, { chat: "c", used: share(64), size: SIZE });
            expect(await motions(fresh)).toEqual([]);
            expect(await drawn(fresh)).toBeCloseTo(0.64, 2);
          } finally {
            await fresh.close();
          }
        } finally {
          await page.close();
        }
      });

      for (const motion of ["ease", "spring"])
        run(`under Reduce Motion a new reading is drawn in one frame (${motion})`, async () => {
          const page = await open(engine, { reducedMotion: "reduce" });
          try {
            await render(page, { chat: "a", used: share(85), size: SIZE, motion });
            await render(page, { chat: "a", used: share(12), size: SIZE, motion });
            expect(await motions(page)).toEqual([]);
            // By the next frame (the page's Reduce Motion transitions are 0.01 ms, shared/desktop.css).
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            expect(await drawn(page)).toBeCloseTo(0.12, 2);
          } finally {
            await page.close();
          }
        });
    });
});
