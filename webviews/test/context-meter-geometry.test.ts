// The Context meter must keep its percentages exact when separators are visible.
// Run with CMUX_BROWSER_TESTS=1; set CMUX_CONTEXT_METER_SHOTS to keep a PNG artifact.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("context-meter-geometry.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("context meter geometry", () => test("browser", () => {}));
    return;
  }
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
    const page: Page = await browser!.newPage({ viewport: { width: 280, height: 180 } });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.context-meter-geometry", {
          variant: "five-equal-categories",
          frame: "component",
          width: 280,
          height: 180,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.waitForSelector('[data-context-meter-fixture="five-equal-categories"] .acpmux-chat-inspector-context__bar');
      const geometry = await page.$eval(
        '[data-context-meter-fixture="five-equal-categories"] .acpmux-chat-inspector-context__bar',
        (bar) => {
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
        },
      );
      console.log(`context-meter-geometry ${JSON.stringify(geometry)}`);
      expect(geometry.spans).toHaveLength(5);
      expect(geometry.gap).toBe("0px");
      expect(Math.abs(geometry.usedEnd - geometry.expectedUsedEnd)).toBeLessThanOrEqual(1);
      const shots = process.env.CMUX_CONTEXT_METER_SHOTS;
      if (shots) {
        await mkdir(shots, { recursive: true });
        await page.screenshot({ path: path.join(shots, "context-meter-after.png") });
      }
    } finally {
      await page.close();
    }
  });
});
