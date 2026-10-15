// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread minimap's motion, measured in WebKit (the engine the app draws the pane in) against the
// Codex desktop app's recordings (minimap-ref SPEC): hover grows the tick to 26 px within 160 ms
// with no delay; a click scrolls on cubic-bezier(0.35, 0.05, 0, 1) for about 400 ms and lands the
// prompt's bubble 35 px below the transcript's top; its bubble's highlight runs 1400 ms. Under
// Reduce Motion none of them animate.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("thread-minimap-motion: skipping (run `bunx playwright install webkit`)");
    describe.skip("thread minimap motion", () => test("webkit", () => {}));
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
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  /// Eighteen prompts, as the reference thread has, with replies tall enough to scroll between.
  const rows = Array.from({ length: 18 }, (_, index) => [
    row(`t${index}-user`, "user", `Reply with only the word ok and the number ${index + 1}. No tools.`),
    row(`t${index}-answer`, "assistant", `ok ${index + 1}\n\nA second paragraph so the turn has some height.`),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();

  async function open(reduce: boolean): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await page.emulateMedia({ reducedMotion: reduce ? "reduce" : "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__tick");
    // To the top, where the later prompts are below and still mounted.
    await page.evaluate(async () => {
      document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
      await new Promise((resolve) => setTimeout(resolve, 300));
    });
    return page;
  }

  /// Samples, every frame for `ms` from now, `probe` (an expression over the page) with its time.
  const sample = (page: Page, ms: number) =>
    page.evaluate((duration) => {
      const samples: { t: number; width: number; scroll: number }[] = [];
      (window as unknown as { __samples: typeof samples }).__samples = samples;
      const start = performance.now();
      return new Promise<void>((resolve) => {
        const step = () => {
          const bar = document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar');
          const matrix = bar ? new DOMMatrixReadOnly(getComputedStyle(bar).transform) : undefined;
          samples.push({
            t: performance.now(),
            width: 26 * (matrix?.a ?? 0),
            scroll: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
          });
          if (performance.now() - start < duration) requestAnimationFrame(step);
          else resolve();
        };
        requestAnimationFrame(step);
      });
    }, ms);
  const samples = (page: Page) =>
    page.evaluate(() => (window as unknown as { __samples: { t: number; width: number; scroll: number }[] }).__samples);
  /// The center of row `index`'s tick, in page coordinates.
  const tickPoint = (page: Page, index: number) =>
    page.evaluate((at) => {
      const box = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
      return { x: box.left + 8, y: box.top + box.height / 2 };
    }, index);
  test("hover grows the tick to 26 px within 160 ms, with no delay, on the spring curve", async () => {
    const page = await open(false);
    const style = await page.evaluate(() => {
      const css = getComputedStyle(document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!);
      return { delay: css.transitionDelay, duration: css.transitionDuration, easing: css.transitionTimingFunction };
    });
    expect(style.delay).toBe("0s");
    expect(style.duration).toBe("0.15s"); // at rest: the 150 ms settle; hovered rows use 160 ms
    const point = await tickPoint(page, 5);
    await page.mouse.move(point.x + 300, point.y);
    // The pointer's arrival starts a transform transition at once (no dwell). Its timeline is read
    // by holding and seeking it, not by sampling frames: a CI runner's headless WebKit paces
    // frames unevenly. The hold starts in the transition's own `transitionrun`.
    await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!;
      const held = window as unknown as { __held?: Animation; __over: number };
      held.__over = 0;
      document.addEventListener("pointerover", () => (held.__over = performance.now()), { once: true, capture: true });
      bar.addEventListener(
        "transitionrun",
        () => {
          const running = bar
            .getAnimations()
            .find((entry) => (entry as CSSTransition).transitionProperty === "transform");
          running?.pause();
          held.__held = running;
          (held as unknown as { __run: number }).__run = performance.now();
        },
        { once: true },
      );
    });
    await page.mouse.move(point.x, point.y);
    await page.waitForFunction(() => "__held" in window, undefined, { timeout: 5_000 });
    const transition = await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!;
      const held = window as unknown as { __held?: Animation; __over: number; __run: number };
      const running = held.__held;
      if (!running) return undefined;
      const timing = running.effect!.getComputedTiming();
      const width = (ms: number) => {
        running.pause();
        running.currentTime = ms;
        return 26 * new DOMMatrixReadOnly(getComputedStyle(bar).transform).a;
      };
      const widths = [0, 40, 80, 112, 160].map(width);
      running.currentTime = 160;
      running.play();
      return {
        duration: timing.duration,
        delay: timing.delay,
        // From the pointer reaching the row to the transition starting.
        wait: held.__run - held.__over,
        widths,
      };
    });
    expect(transition).toBeDefined();
    expect(transition!.wait).toBeLessThan(60);
    // 160 ms, no delay, on the spring (the CSS `linear()` curve, or its cubic-bezier fallback).
    expect(transition!.duration).toBe(160);
    expect(transition!.delay).toBe(0);
    const [w0, w40, w80, w112, w160] = transition!.widths;
    // From the 6 px rest through the lengths between (a transition, not a jump) to 26 px.
    expect(Math.round(w0!)).toBe(6);
    expect(w40!).toBeGreaterThan(8);
    expect(w40!).toBeLessThan(25.4);
    expect(w80!).toBeGreaterThan(w40!);
    // The spring's small overshoot (about 0.8%), then 26 px.
    expect(w112!).toBeLessThan(26 * 1.012);
    expect(Math.round(w160!)).toBe(26);
    const hovered = await page.evaluate(() => {
      const css = getComputedStyle(document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!);
      return { delay: css.transitionDelay, duration: css.transitionDuration };
    });
    expect(hovered).toEqual({ delay: "0s", duration: "0.16s" });
    await page.close();
  });

  test("a click scrolls about 400 ms on the measured curve, lands the bubble 35 px down and highlights it 1400 ms", async () => {
    const page = await open(false);
    // The mounted prompt about 650 px down.
    const target = await page.evaluate(() => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      const prompts = [...document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-user")];
      const pick = prompts.find((node) => node.getBoundingClientRect().top - view.top > 620)!;
      return Number(pick.dataset.rowId!.replace(/^t(\d+)-user$/, "$1"));
    });
    const point = await tickPoint(page, target);
    await page.mouse.move(point.x, point.y);
    await page.waitForTimeout(400);
    const sampling = sample(page, 900);
    // The click, while the target's row is mounted (an unmounted one jumps at once, by design).
    const mounted = await page.evaluate((index) => {
      const row = document.querySelector(`.acpmux-row[data-row-id="t${index}-user"]`);
      (window as unknown as { __over: number }).__over = performance.now();
      document.querySelector<HTMLElement>(`[data-tick="${index}"]`)!.click();
      return row !== null;
    }, target);
    expect(mounted).toBe(true);
    await sampling;
    const clicked = await page.evaluate(() => (window as unknown as { __over: number }).__over);
    const scrolls = (await samples(page)).filter((entry) => entry.t >= clicked);
    const final = scrolls.at(-1)!.scroll;
    expect(final).toBeGreaterThan(500);
    const landed = scrolls.find((entry) => Math.abs(entry.scroll - final) < 0.5)!;
    // About 400 ms for about 650 px.
    expect(landed.t - clicked).toBeGreaterThan(320);
    expect(landed.t - clicked).toBeLessThan(500);
    // The curve: slow out of the start (cubic-bezier(0.35, 0.05, 0, 1)), past 85% by 60% of the time.
    const progress = (ms: number) => scrolls.find((entry) => entry.t - clicked >= ms)!.scroll / final;
    expect(progress(40)).toBeLessThan(0.12);
    expect(progress(240)).toBeGreaterThan(0.85);
    const landing = await page.evaluate((index) => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      const bubble = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="t${index}-user"] .cv-user__bubble`)!;
      const animation = bubble.getAnimations().find((entry) => entry.id === "acpmux-landing");
      const timing = animation?.effect?.getTiming();
      return {
        offset: bubble.getBoundingClientRect().top - view.top,
        duration: timing?.duration,
        easing: timing?.easing,
      };
    }, target);
    expect(Math.abs(landing.offset - 35)).toBeLessThanOrEqual(1);
    expect(landing.duration).toBe(1400);
    expect(landing.easing?.replace(/\s/g, "")).toBe("cubic-bezier(0.23,1,0.32,1)");
    await page.close();
  });

  test("under Reduce Motion the tick, the scroll and the highlight do not animate", async () => {
    const page = await open(true);
    const point = await tickPoint(page, 9);
    await page.mouse.move(point.x, point.y);
    await page.waitForTimeout(50);
    const hovered = await page.evaluate(() => {
      const css = getComputedStyle(document.querySelector<HTMLElement>('[data-tick="9"] .acpmux-minimap__bar')!);
      return { duration: css.transitionDuration, width: 26 * new DOMMatrixReadOnly(css.transform).a };
    });
    // No transition (an engine may report a stylesheet's near-zero reduce-motion duration).
    expect(parseFloat(hovered.duration)).toBeLessThan(0.001);
    expect(Math.round(hovered.width)).toBe(26);
    const result = await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const before = scroller.scrollTop;
      document.querySelector<HTMLElement>('[data-tick="9"]')!.click();
      const after = scroller.scrollTop;
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const bubble = document.querySelector<HTMLElement>('.acpmux-row[data-row-id="t9-user"] .cv-user__bubble');
      return {
        moved: after !== before,
        settled: scroller.scrollTop === after,
        animations: bubble?.getAnimations().filter((entry) => entry.id === "acpmux-landing").length ?? 0,
      };
    });
    expect(result).toEqual({ moved: true, settled: true, animations: 0 });
    await page.close();
  });
});
