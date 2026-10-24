// New Tab lists move with their rows (motion pass, 2026-10-12): when a tab closes, its row joins
// Recently Closed at the top and the rows under it slide down from where they were drawn, instead
// of every row jumping a slot in one frame. The new row is drawn where it lands at once, with no
// fade (Leo 2026-10-22: no entry animations on the New Tab). Reduced motion drops the slides too
// (plans/cmux-next/motion.md rule 7).
// This drives the real gallery page through the bridge the app uses (applyRecentlyClosed).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-list-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-list-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab list motion", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  // The gallery stands in for the app's Reduce Motion (its media and its motion tokens) by `reducedMotion=1`.
  const url = (variant: string, reduced = false) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant, reducedMotion: reduced ? 1 : undefined })}`;

  async function ready(page: Page) {
    for (;;) {
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        return;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "recently-closed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A page that records every transform or opacity animation as it starts (Web Animations and
   * CSS transitions), so a short fade that ends before the test reads is still counted. */
  async function recordingPage() {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      type Started = { target: Element; properties: string[] };
      const started: Started[] = [];
      (window as unknown as { startedMotion: Started[] }).startedMotion = started;
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (keyframes, options) {
        const frames = Array.isArray(keyframes) ? keyframes : keyframes ? [keyframes] : [];
        const properties = frames.flatMap((frame) => Object.keys(frame as object));
        started.push({
          target: this,
          properties: properties.filter((key) => key === "transform" || key === "opacity"),
        });
        return animate.call(this, keyframes, options);
      };
      document.addEventListener("transitionrun", (event) => {
        if (event.propertyName === "transform" || event.propertyName === "opacity")
          started.push({ target: event.target as Element, properties: [event.propertyName] });
      });
    });
    return page;
  }

  async function open(reduced: boolean) {
    const page = await recordingPage();
    await page.goto(url("recently-closed", reduced));
    await ready(page);
    await page.locator(".nt-screen").first().waitFor();
    return page;
  }

  /** Once the rows' motion so far has started (a painted frame after they drew) and run out. */
  async function rowsSettle(page: Page) {
    await page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await Promise.all(
        document
          .getAnimations()
          .filter((animation) => Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)))
          .map((animation) => animation.finished.catch(() => undefined)),
      );
    });
  }

  /** Forgets the motion started so far. */
  async function forget(page: Page) {
    await page.evaluate(() => {
      (window as unknown as { startedMotion: unknown[] }).startedMotion.length = 0;
    });
  }

  /** Shows `ids` as Recently Closed, newest first, and waits until the list draws them. */
  async function closed(page: Page, ids: string[]) {
    await page.evaluate((ids) => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge?: { applyRecentlyClosed?(items: unknown): void } })
        .cmuxAcpmuxBridge;
      bridge?.applyRecentlyClosed?.(
        ids.map((id, index) => ({
          id,
          kind: "terminal",
          title: `Closed ${id}`,
          available: true,
          closedAt: Date.now() - (index + 1) * 60_000,
        })),
      );
    }, ids);
    await page.waitForFunction(
      (first) => document.querySelector(".nt-closed .nt-row-title")?.textContent === `Closed ${first}`,
      ids[0],
    );
  }

  /** The motion each Recently Closed row started since `forget`: by title, its properties. */
  async function motion(page: Page) {
    return page.evaluate(() => {
      const started = (window as unknown as { startedMotion: { target: Element; properties: string[] }[] })
        .startedMotion;
      return Object.fromEntries(
        [...document.querySelectorAll<HTMLElement>(".nt-closed .nt-row-host > .nt-row")].map((row) => {
          const properties = started.filter((entry) => entry.target === row).flatMap((entry) => entry.properties);
          return [row.querySelector(".nt-row-title")?.textContent ?? "", [...new Set(properties)].sort()];
        }),
      );
    });
  }

  test("a closed tab's row appears at once at the top and the rows under it slide down", async () => {
    const page = await open(false);
    try {
      await closed(page, ["a", "b", "c", "d"]);
      await rowsSettle(page);
      await forget(page);
      await closed(page, ["e", "a", "b", "c", "d"]);
      expect(await motion(page)).toEqual({
        "Closed e": [],
        "Closed a": ["transform"],
        "Closed b": ["transform"],
        "Closed c": ["transform"],
        "Closed d": ["transform"],
      });
    } finally {
      await page.close();
    }
  });

  test("with reduced motion the new row appears at once and nothing slides", async () => {
    const page = await open(true);
    try {
      await closed(page, ["a", "b", "c", "d"]);
      await rowsSettle(page);
      await forget(page);
      await closed(page, ["e", "a", "b", "c", "d"]);
      expect(await motion(page)).toEqual({
        "Closed e": [],
        "Closed a": [],
        "Closed b": [],
        "Closed c": [],
        "Closed d": [],
      });
    } finally {
      await page.close();
    }
  });
});
