// The classic New Tab (`tabs.newTabTemplate: classic`, App.tsx renders NewTabPage) has no entry
// animations either (Leo 2026-10-22): its project chooser opens in the frame it is asked for. This
// opens it on the real gallery page in Chromium and reads what animates in it. Skipped where
// Chromium is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-no-entry-classic.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("classic new tab no entry", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.new-tab-page";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
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

  test("project results alone scroll; the popover never adds a second scrollbar", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "idle" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
      await page.click(".acpmux-project-button");
      const popup = page.locator(".acpmux-project-menu");
      await popup.waitFor();
      expect(await popup.evaluate((node) => getComputedStyle(node).overflowY)).toBe("visible");
      expect(await popup.locator(".ui-combobox-viewport").count()).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("the classic footer refits after leaving and returning to Agent", async () => {
    const page = await browser!.newPage({ viewport: { width: 420, height: 700 } });
    try {
      await page.addInitScript(() => {
        const Native = window.ResizeObserver;
        let observed = 0;
        Object.defineProperty(window, "__cmuxFooterFitObserves", { get: () => observed });
        window.ResizeObserver = class extends Native {
          observe(target: Element, options?: ResizeObserverOptions) {
            if (target.classList.contains("acpmux-composer-foot")) observed++;
            super.observe(target, options);
          }
        };
      });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "idle" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
      const observed = () =>
        page.evaluate(() => (window as typeof window & { __cmuxFooterFitObserves: number }).__cmuxFooterFitObserves);
      const before = await observed();
      expect(before).toBeGreaterThan(0);
      await page.click('.acpmux-newtab-kind[title*="Terminal"]');
      await page.waitForFunction(
        () => document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal",
      );
      await page.click('.acpmux-newtab-kind[title*="Agent"]');
      await page.waitForFunction(() => document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
      expect(await observed()).toBeGreaterThan(before);
    } finally {
      await page.close();
    }
  });

  test("the classic New Tab's project chooser opens at once", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "idle" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
      await page.click(".acpmux-project-button");
      await page.waitForSelector(".acpmux-project-menu");
      // raf-read: reads the running animations, not layout. An open runs for 120ms, past two frames.
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const seen = await page.evaluate(() => ({
        marked: document.documentElement.hasAttribute("data-new-tab"),
        // Under 1ms draws at once (desktop.css's Reduce Motion cut is 0.01ms).
        entrances: document
          .getAnimations()
          .filter((animation) => Number(animation.effect?.getComputedTiming().activeDuration ?? 0) >= 1)
          .map((animation) => ({ animation, target: (animation.effect as KeyframeEffect | null)?.target as Element }))
          .filter(({ target }) => target?.closest(".ui-popup, .acpmux-menu"))
          .map(
            ({ animation, target }) =>
              `${(animation as CSSAnimation).animationName ?? "transition"} on ${target.className}`,
          ),
      }));
      expect(seen).toEqual({ marked: true, entrances: [] });
    } finally {
      await page.close();
    }
  });
});
