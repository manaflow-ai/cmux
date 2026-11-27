// l10n-allow-file: browser fixture labels, not shipped UI.
// cmux-web-test-timeout: 300
// The guest page's open-in-app banner (OpenInApp.tsx, guest.css) fits a phone: at 320 px wide every control
// sits inside the banner and the banner inside the viewport (#38282: "Continue in browser" ran past its edge).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { ViteDevServer } from "vite";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("guest-open-in-app-banner-browser.test.ts", async () => {
  const SHARE = "c2hhcmUtYmFubmVyLW5hcnJvdw";
  setDefaultTimeout(240_000);
  let vite: ViteDevServer;
  let browser: Browser;
  let origin: string;

  beforeAll(async () => {
    const { createServer } = await import("vite");
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.guest-page.mjs"),
      base: "/",
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, `/g/${SHARE}`);
    origin = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [320, 390, 1024]) {
    test(`at ${width} px every banner control sits inside the banner and the banner inside the viewport`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 700 }, deviceScaleFactor: 2 });
      // The page asks the app; nothing here answers, so the banner holds until the attempt's timer.
      await page.addInitScript(() => {
        const timeout = window.setTimeout.bind(window);
        window.setTimeout = ((handler: TimerHandler, ms?: number, ...rest: unknown[]) =>
          timeout(handler, ms === 1500 ? 600_000 : ms, ...rest)) as typeof window.setTimeout;
      });
      await page.route(/^cmux-dev:/, (route) => route.abort());
      await page.goto(`${origin}/g/${SHARE}?app=cmux-dev#c2VjcmV0LWJhbm5lcg`);
      const banner = page.getByTestId("guest-open-in-app");
      await banner.waitFor();
      // The dev server injects the stylesheet as a module: measure once it applies.
      await page.waitForFunction(() => {
        const element = document.querySelector("[data-testid=guest-open-in-app]");
        return element !== null && getComputedStyle(element).position === "fixed";
      });
      const boxes = await banner.evaluate((element) => {
        const box = (node: Element) => {
          const { left, right, width } = node.getBoundingClientRect();
          return { left, right, width };
        };
        return {
          banner: box(element),
          parts: [...element.children].map((child) => ({ name: child.className, ...box(child) })),
          viewport: document.documentElement.clientWidth,
        };
      });
      expect(boxes.banner.left).toBeGreaterThanOrEqual(0);
      expect(boxes.banner.right).toBeLessThanOrEqual(boxes.viewport);
      expect(boxes.parts.length).toBe(3);
      for (const part of boxes.parts) {
        expect({
          part: part.name,
          inside: part.left >= boxes.banner.left - 0.5 && part.right <= boxes.banner.right + 0.5,
        }).toEqual({ part: part.name, inside: true });
        expect(part.width).toBeGreaterThan(0);
      }
      await page.close();
    });
  }
});
