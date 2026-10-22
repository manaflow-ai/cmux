// The classic New Tab (`tabs.newTabTemplate: classic`, App.tsx renders NewTabPage) is a New Tab
// page too (Leo 2026-10-22: "we should basically have no entry animations a lot of the time, esp
// here all over the new tab area... exit animations are ok tho."): its project chooser opens in the
// frame it is asked for, as the other templates' menus do (newtab/noEntryMotion.ts). This opens the
// chooser on the real gallery page and records every animation and transition that starts.
// new-tab-no-entry-menus.test.ts checks each shared surface on the pane's stylesheet.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-no-entry-classic.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-no-entry-classic: skipping (run `bunx playwright install chromium`)");
    describe.skip("classic new tab no entry", () => test("chromium", () => {}));
    return;
  }

  const ENTRY = "agent-pane.new-tab-page";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: "idle" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "idle" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// A page that records each animation and transition as it starts, with the time it runs for, so
  /// a short fade that ends before the test reads is still counted.
  async function recordingPage(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await page.addInitScript(() => {
      const started: { surface: string; what: string; seconds: number }[] = [];
      (window as unknown as { startedMotion: typeof started }).startedMotion = started;
      const seconds = (value: string) =>
        Math.max(
          0,
          ...value.split(",").map((part) => {
            const number = Number.parseFloat(part);
            return part.trim().endsWith("ms") ? number / 1000 : number;
          }),
        );
      const record = (event: Event, what: string, duration: (style: CSSStyleDeclaration) => string) => {
        const target = event.target as Element;
        const surface = target.closest(".ui-popup, .acpmux-menu")?.className ?? "";
        if (!surface) return;
        started.push({ surface, what, seconds: seconds(duration(getComputedStyle(target))) });
      };
      document.addEventListener(
        "animationstart",
        (event) => record(event, (event as AnimationEvent).animationName, (style) => style.animationDuration),
        true,
      );
      document.addEventListener(
        "transitionstart",
        (event) => record(event, (event as TransitionEvent).propertyName, (style) => style.transitionDuration),
        true,
      );
    });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
    return page;
  }

  test("the classic New Tab's project chooser opens at once", async () => {
    const page = await recordingPage();
    try {
      await page.click(".acpmux-project-button");
      await page.waitForSelector(".acpmux-project-menu");
      // Two painted frames: an open animation or transition has started by then.
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const seen = await page.evaluate(() => ({
        marked: document.documentElement.hasAttribute("data-new-tab"),
        // Under 1ms draws at once (desktop.css's Reduce Motion cut is 0.01ms).
        entrances: (
          window as unknown as { startedMotion: { surface: string; what: string; seconds: number }[] }
        ).startedMotion
          .filter((entry) => entry.seconds >= 0.001)
          .map((entry) => `${entry.what} on ${entry.surface}`),
      }));
      expect(seen).toEqual({ marked: true, entrances: [] });
    } finally {
      await page.close();
    }
  });
});
