// HIDDEN-PAGE LOOPS (p03-rendering-120, feature `hiddenPageLoops`) in Chromium: once the host says a
// page is hidden or occluded (WebTheme's `cmuxTheme.visibility(false)`, PageWebView+HiddenLoops.swift),
// the page runs no animation and no animation-frame callback, even though its engine still draws
// it (a window under another cmux window). On the show the held callbacks run, the animations play
// again and the shared spinner is back on its phase.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hidden-page-no-frames.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("hidden-page-no-frames: skipping (run `bunx playwright install chromium`)");
    describe.skip("hidden page no frames", () => test("chromium", () => {}));
    return;
  }

  const bootstrap = readWebThemeBootstrap();
  const spinnerClock = await Bun.build({
    entrypoints: [path.join(import.meta.dir, "support/installSpinnerClock.entry.ts")],
    target: "browser",
  }).then((result) => result.outputs[0].text());
  const PERIOD = 900;
  const style =
    `@keyframes cmux-spin { to { transform: rotate(360deg); } }` +
    `.spinner { width: 10px; height: 10px; animation: cmux-spin ${PERIOD}ms linear infinite; }`;

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  type Probe = { callbacks: number; held: number };
  type ProbeWindow = Window & {
    cmuxTheme: { visibility(shown: boolean): void; framesAllowed(): boolean };
    probe: Probe;
  };

  /** A page with a spinner, an infinite script animation and a self-rescheduling frame loop that
   * started before the host's first visibility call, as a page's loop starts before its load ends. */
  async function page(): Promise<Page> {
    const p = await browser!.newPage();
    await p.setContent(`<style>${style}</style><div class="spinner"></div><div id="pulse"></div>`);
    await p.addScriptTag({ content: bootstrap });
    await p.addScriptTag({ content: spinnerClock });
    await p.evaluate(() => {
      const w = window as unknown as ProbeWindow;
      w.probe = { callbacks: 0, held: 0 };
      document
        .getElementById("pulse")!
        .animate([{ opacity: 1 }, { opacity: 0.5 }], { duration: 700, iterations: Infinity });
      const loop = () => {
        // raf-read: the loop is the probe; it counts its own callbacks and reads nothing painted
        w.probe.callbacks++;
        requestAnimationFrame(loop);
      };
      requestAnimationFrame(loop);
    });
    await frames(p, 3);
    return p;
  }

  /** Waits until the page's own frame loop ran `count` more callbacks. */
  async function frames(p: Page, count: number) {
    const from = await callbacks(p);
    await p.waitForFunction((at) => (window as unknown as ProbeWindow).probe.callbacks >= at, from + count);
  }

  const callbacks = (p: Page) => p.evaluate(() => (window as unknown as ProbeWindow).probe.callbacks);
  const running = (p: Page) =>
    p.evaluate(() => document.getAnimations().filter((animation) => animation.playState === "running").length);
  const visibility = (p: Page, shown: boolean) =>
    p.evaluate((value) => (window as unknown as ProbeWindow).cmuxTheme.visibility(value), shown);

  test("a hidden page runs 0 animations and 0 frame callbacks over one second", async () => {
    const p = await page();
    await visibility(p, true);
    await frames(p, 3);
    expect(await running(p)).toBe(2);
    expect(await p.evaluate(() => document.documentElement.hasAttribute("data-cmux-hidden"))).toBe(false);

    await visibility(p, false);
    expect(await p.evaluate(() => document.documentElement.hasAttribute("data-cmux-hidden"))).toBe(true);
    expect(await p.evaluate(() => (window as unknown as ProbeWindow).cmuxTheme.framesAllowed())).toBe(false);
    const before = await callbacks(p);
    expect(await running(p)).toBe(0);
    // The acceptance is a count over one second of the page's own time: the engine keeps drawing it.
    const during = await p.evaluate(
      () =>
        new Promise<{ callbacks: number; running: number; requested: number }>((resolve) => {
          const w = window as unknown as ProbeWindow;
          const start = w.probe.callbacks;
          // A loop asked for while hidden waits too.
          let requested = 0;
          requestAnimationFrame(() => requested++);
          // fixed-wait: the acceptance measures callbacks over one second of a hidden page
          setTimeout(
            () =>
              resolve({
                callbacks: w.probe.callbacks - start,
                running: document.getAnimations().filter((animation) => animation.playState === "running").length,
                requested,
              }),
            1_000,
          );
        }),
    );
    expect(during).toEqual({ callbacks: 0, running: 0, requested: 0 });
    expect(await callbacks(p)).toBe(before);

    await visibility(p, true);
    await frames(p, 3);
    expect(await running(p)).toBe(2);
    await p.close();
  });

  test("a script animation started while hidden waits for the show", async () => {
    const p = await page();
    await visibility(p, false);
    const state = await p.evaluate(
      () =>
        document.body.animate([{ opacity: 1 }, { opacity: 0.9 }], { duration: 500, iterations: Infinity }).playState,
    );
    expect(state).toBe("paused");
    expect(await running(p)).toBe(0);
    await visibility(p, true);
    await frames(p, 2);
    expect(await running(p)).toBe(3);
    await p.close();
  });

  test("visibilitychange hides the page too once the host spoke, and the spinner shows in phase", async () => {
    const p = await page();
    await visibility(p, true);
    const setState = (state: "hidden" | "visible") =>
      p.evaluate((value) => {
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => value });
        document.dispatchEvent(new Event("visibilitychange"));
      }, state);
    await setState("hidden");
    expect(await p.evaluate(() => document.documentElement.hasAttribute("data-cmux-hidden"))).toBe(true);
    expect(await running(p)).toBe(0);
    // Let the paused spinner fall behind the shared clock.
    const at = await p.evaluate(() => Number(document.timeline.currentTime));
    await p.waitForFunction((from) => Number(document.timeline.currentTime) > from + 337, at);
    await setState("visible");
    await frames(p, 2);
    const spinner = await p.evaluate(() => {
      const animation = document.getAnimations().find((a) => (a as CSSAnimation).animationName === "cmux-spin")!;
      return { start: Number(animation.startTime), origin: performance.timeOrigin, state: animation.playState };
    });
    expect(spinner.state).toBe("running");
    const phase = (((spinner.start + spinner.origin) % PERIOD) + PERIOD) % PERIOD;
    expect(Math.min(phase, PERIOD - phase)).toBeLessThan(0.01);
    await p.close();
  });

  test("a frame cancelled while held never runs, and one asked for before the gate still cancels", async () => {
    const p = await browser!.newPage();
    await p.setContent("<div></div>");
    await p.addScriptTag({ content: bootstrap });
    const ran = await p.evaluate(
      () =>
        new Promise<string[]>((resolve) => {
          const w = window as unknown as ProbeWindow;
          const seen: string[] = [];
          const early = requestAnimationFrame(() => seen.push("early"));
          w.cmuxTheme.visibility(true);
          cancelAnimationFrame(early);
          w.cmuxTheme.visibility(false);
          const held = requestAnimationFrame(() => seen.push("held"));
          requestAnimationFrame(() => seen.push("kept"));
          cancelAnimationFrame(held);
          w.cmuxTheme.visibility(true);
          requestAnimationFrame(() => requestAnimationFrame(() => resolve(seen)));
        }),
    );
    expect(ran).toEqual(["kept"]);
    await p.close();
  });
});
