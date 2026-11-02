// The Context meter must keep its percentages exact when separators are visible.
// Run with CMUX_BROWSER_TESTS=1; set CMUX_CONTEXT_METER_SHOTS to keep PNG artifacts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("context-meter-geometry.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.context-meter-geometry", {
      browser,
      params: { variant: "five-equal-categories", frame: "component", width: 280, height: 180 },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("five equal categories end at exactly their 95% allocation", async () => {
    const page: Page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const shots = process.env.CMUX_CONTEXT_METER_SHOTS;
    const baseline = process.env.CMUX_CONTEXT_METER_BASELINE === "1";
    const cases = [
      {
        name: "light-narrow",
        theme: "Apple System Colors Light",
        viewport: { width: 900, height: 760 },
        variant: "five-equal-categories",
        frameWidth: 280,
      },
      {
        name: "light-wide",
        theme: "Apple System Colors Light",
        viewport: { width: 1600, height: 940 },
        variant: "five-equal-categories-wide",
        frameWidth: 420,
      },
      {
        name: "dark-narrow",
        theme: "Apple System Colors",
        viewport: { width: 900, height: 760 },
        variant: "five-equal-categories",
        frameWidth: 280,
      },
      {
        name: "dark-wide",
        theme: "Apple System Colors",
        viewport: { width: 1600, height: 940 },
        variant: "five-equal-categories-wide",
        frameWidth: 420,
      },
    ];
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      for (const item of cases) {
        await page.setViewportSize(item.viewport);
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.context-meter-geometry", {
            variant: item.variant,
            frame: "component",
            width: item.frameWidth,
            height: 180,
            theme: item.theme,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const selector = '[data-context-meter-fixture="five-equal-categories"] .acpmux-session-info-context__bar';
        await page.waitForSelector(selector);
        if (shots) {
          const dir = path.join(shots, item.name);
          await mkdir(dir, { recursive: true });
          await page.locator('[data-context-meter-fixture="five-equal-categories"]').screenshot({
            path: path.join(dir, "context-meter.png"),
          });
        }
        const geometry = await page.$eval(selector, (bar) => {
          const rect = bar.getBoundingClientRect();
          const spans = [...bar.querySelectorAll<HTMLElement>(":scope > span")].map((span) => {
            const box = span.getBoundingClientRect();
            return { left: box.left, right: box.right, width: box.width };
          });
          const expectedUsed = rect.width * 0.95;
          return {
            bar: { left: rect.left, right: rect.right, width: rect.width },
            spans,
            usedEnd: spans.at(-1)?.right ?? rect.left,
            expectedUsedEnd: rect.left + expectedUsed,
            gap: getComputedStyle(bar).gap,
          };
        });
        console.log(`context-meter-geometry ${item.name} ${JSON.stringify(geometry)}`);
        if (baseline) {
          expect(geometry.spans).toHaveLength(5);
          expect(geometry.gap).toBe("2px");
          expect(geometry.usedEnd - geometry.expectedUsedEnd).toBeGreaterThan(7);
        } else {
          expect(geometry.spans).toHaveLength(5);
          expect(geometry.gap).toBe("0px");
          expect(Math.abs(geometry.usedEnd - geometry.expectedUsedEnd)).toBeLessThanOrEqual(1);
        }
      }
    } finally {
      await page.close();
    }
  });

  if (process.env.CMUX_CONTEXT_METER_CAPTURE_ONLY !== "1") {
    test("tiny positive categories keep colored fill under their separator", async () => {
      const page: Page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.context-meter-geometry", {
            variant: "tiny-positive-category",
            frame: "component",
            width: 280,
            height: 180,
            theme: "Apple System Colors Light",
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const selector = '[data-context-meter-fixture="tiny-positive-category"] .acpmux-session-info-context__bar';
        await page.waitForSelector(selector);
        const geometry = await page.$eval(selector, (bar) => {
          const spans = [...bar.querySelectorAll<HTMLElement>(":scope > span")];
          const tiny = spans[1]!;
          const tinyBox = tiny.getBoundingClientRect();
          const separator = getComputedStyle(tiny, "::after");
          return {
            spanCount: spans.length,
            tinyWidth: tinyBox.width,
            tinyColor: getComputedStyle(tiny).backgroundColor,
            separatorColor: separator.backgroundColor,
            separatorWidth: Number.parseFloat(separator.width),
          };
        });
        console.log(`context-meter-geometry tiny-positive-category ${JSON.stringify(geometry)}`);
        expect(geometry.spanCount).toBe(3);
        expect(geometry.tinyWidth).toBeGreaterThanOrEqual(2);
        expect(geometry.separatorWidth).toBeGreaterThan(0);
        expect(geometry.separatorWidth).toBeLessThan(geometry.tinyWidth);
        expect(geometry.separatorColor).not.toBe(geometry.tinyColor);
      } finally {
        await page.close();
      }
    });
  }
});
