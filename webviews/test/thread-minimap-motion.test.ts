// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread minimap's motion, measured in WebKit (the engine the app draws the pane in) against the
// Codex desktop app's recordings (minimap-ref SPEC): hover grows the tick to 26 px within 120 ms
// (the motion scale's micro step; Codex's spring curve, run faster than its 160 ms)
// with no delay; a click lands the prompt's bubble 35 px below the transcript's top at once, with no
// glide (Leo, 2026-10-29: "faster scrttoll"; it scrolled about 400 ms on Codex's curve before); its bubble's highlight runs 1400 ms. Under
// Reduce Motion none of them animate.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  // The probe gets 30 s, not Playwright's 180 s default, which is longer than the runner's 120 s per-file
  // limit (run-webviews-tests.sh). On the fleet's aws Macs, where steps run over SSH as ec2-user, WebKit
  // never answers its launch (Chromium starts there in 300 ms). The default made the runner kill the
  // file before its skip could run (TIMEOUT on aws-m4pro-3 and -6, 2026-10-22). Where the lane is
  // required (GitHub Actions), a WebKit that does not launch fails the file instead (probeEngineOrSkip).
  if (!(await probeEngineOrSkip("thread minimap motion", "webkit", webkit))) return;
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
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: reduce ? "reduce" : "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__tick");
    // To the top, where the later prompts are below and still mounted.
    await page.evaluate(() => {
      document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
    });
    await settled(page);
    return page;
  }

  /// Until no animation is left running and the transcript has held its scroll position over three
  /// painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      for (let tries = 0; tries < 20; tries++) {
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let last = -1;
          let still = 0;
          window.cmuxAfterPaint(() => {
            still = node.scrollTop === last ? still + 1 : 0;
            last = node.scrollTop;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
        if (finite().every((animation) => animation.playState !== "running")) return;
      }
    });

  /// Samples, after every painted frame for `ms` from now, the tick's bar width and the transcript's
  /// offset, with the time.
  const sample = (page: Page, ms: number) =>
    page.evaluate((duration) => {
      const samples: { t: number; width: number; scroll: number }[] = [];
      (window as unknown as { __samples: typeof samples }).__samples = samples;
      const start = performance.now();
      return new Promise<void>((resolve) => {
        window.cmuxAfterPaint(() => {
          const bar = document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar');
          const matrix = bar ? new DOMMatrixReadOnly(getComputedStyle(bar).transform) : undefined;
          samples.push({
            t: performance.now(),
            width: 26 * (matrix?.a ?? 0),
            scroll: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
          });
          if (performance.now() - start < duration) return true;
          resolve();
          return false;
        });
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
  test("hover grows the tick to 26 px within 120 ms, with no delay, on the spring curve", async () => {
    const page = await open(false);
    const style = await page.evaluate(() => {
      const css = getComputedStyle(document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!);
      return {
        property: css.transitionProperty,
        delay: css.transitionDelay,
        duration: css.transitionDuration,
        easing: css.transitionTimingFunction,
      };
    });
    // At rest the bar also fades its opacity as the band moves (the wave): both properties start
    // at once and run the scale's micro step.
    expect(style.property).toBe("transform, opacity");
    expect(style.delay).toBe("0s, 0s");
    expect(style.duration).toBe("0.12s, 0.12s");
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
      const widths = [0, 30, 60, 84, 120].map(width);
      running.currentTime = 120;
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
    // 120 ms, no delay, on the spring (the CSS `linear()` curve, or its cubic-bezier fallback).
    expect(transition!.duration).toBe(120);
    expect(transition!.delay).toBe(0);
    const [w0, w30, w60, w84, w120] = transition!.widths;
    // From the 6 px rest through the lengths between (a transition, not a jump) to 26 px.
    expect(Math.round(w0!)).toBe(6);
    expect(w30!).toBeGreaterThan(8);
    expect(w30!).toBeLessThan(25.4);
    expect(w60!).toBeGreaterThan(w30!);
    // The spring's small overshoot (about 0.8%), then 26 px.
    expect(w84!).toBeLessThan(26 * 1.012);
    expect(Math.round(w120!)).toBe(26);
    const hovered = await page.evaluate(() => {
      const css = getComputedStyle(document.querySelector<HTMLElement>('[data-tick="5"] .acpmux-minimap__bar')!);
      return { delay: css.transitionDelay, duration: css.transitionDuration };
    });
    expect(hovered).toEqual({ delay: "0s", duration: "0.12s" });
    await page.close();
  });

  test("a click lands the bubble 35 px down at once, with no glide, and highlights it 1400 ms", async () => {
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
    // The hover settles: the tick grown and its preview card open.
    await page.locator(".acpmux-minimap__card").waitFor({ timeout: 5_000 });
    await settled(page);
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
    // Every frame after the click already shows the landing: the scroll was set in the click's task.
    expect(scrolls.length).toBeGreaterThan(0);
    for (const entry of scrolls) expect(Math.abs(entry.scroll - final)).toBeLessThanOrEqual(1);
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

  // Only a rail click lands at once; Next Turn (Ctrl-Opt-Down) keeps its glide on the step curve.
  test("Next Turn still glides to the next prompt over the step's duration", async () => {
    const page = await open(false);
    await page.mouse.move(900, 400);
    await settled(page);
    const sampling = sample(page, 900);
    await page.evaluate(() => {
      (window as unknown as { __over: number }).__over = performance.now();
      window.dispatchEvent(new CustomEvent("cmux-acpmux-nextTurn"));
    });
    await sampling;
    const started = await page.evaluate(() => (window as unknown as { __over: number }).__over);
    const scrolls = (await samples(page)).filter((entry) => entry.t >= started);
    const final = scrolls.at(-1)!.scroll;
    expect(final).toBeGreaterThan(0);
    // Some painted frame shows the scroll part of the way there, and it lands after a few frames.
    expect(scrolls.some((entry) => entry.scroll > 1 && entry.scroll < final - 1)).toBe(true);
    const landed = scrolls.find((entry) => Math.abs(entry.scroll - final) <= 1)!;
    expect(landed.t - started).toBeGreaterThan(50);
    await page.close();
  });

  /// The flash's keyframe colors' alpha, read off the landing animation on the clicked prompt's bubble.
  async function landingAlphas(page: Page, index: number): Promise<number[]> {
    return page.evaluate(async (index) => {
      document.querySelector<HTMLElement>(`[data-tick="${index}"]`)!.click();
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      const bubble = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="t${index}-user"] .cv-user__bubble`)!;
      const animation = bubble.getAnimations().find((entry) => entry.id === "acpmux-landing");
      const frames = (animation?.effect as KeyframeEffect | null)?.getKeyframes() ?? [];
      // Resolve each color through a probe, so color-mix() and named colors come back as rgb()/color().
      const probe = document.createElement("div");
      document.body.append(probe);
      const alphas = frames.map((frame) => {
        probe.style.backgroundColor = String(frame.backgroundColor ?? "");
        const color = getComputedStyle(probe).backgroundColor;
        const alpha = /\/\s*([\d.]+)\s*\)$/.exec(color)?.[1] ?? /^rgba\([^)]*,\s*([\d.]+)\)$/.exec(color)?.[1];
        return alpha === undefined ? 1 : Number(alpha);
      });
      probe.remove();
      return alphas;
    }, index);
  }

  // Leo 2026-10-20: the prompt bubble is glass, never opaque, not even while it flashes.
  test("the landing flash stays glass: every frame is translucent", async () => {
    const page = await open(false);
    const alphas = await landingAlphas(page, 9);
    expect(alphas.length).toBe(3);
    for (const alpha of alphas) expect(alpha).toBeLessThan(1);
    await page.close();
  });

  // Reduce Transparency makes the bubble opaque (glass.css), and its flash with it: no frame lets the
  // backdrop through.
  test("under Reduce Transparency every frame of the landing flash is opaque", async () => {
    const page = await open(false);
    await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
    const alphas = await landingAlphas(page, 9);
    expect(alphas.length).toBe(3);
    for (const alpha of alphas) expect(alpha).toBe(1);
    await page.close();
  });

  test("under Reduce Motion the tick, the scroll and the highlight do not animate", async () => {
    const page = await open(true);
    const point = await tickPoint(page, 9);
    await page.mouse.move(point.x, point.y);
    await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
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
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
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
