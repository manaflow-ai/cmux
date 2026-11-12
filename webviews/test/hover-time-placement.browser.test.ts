// cmux-web-test-timeout: 300
// l10n-allow-file: browser regression descriptions and fixture selectors.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("hover-time-placement.browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("hover time placement", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  const entry = "agent-pane.hover-time-placement";
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, entry, { params: { variant: "inline" } });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const width of [360, 760])
    test(`hover time stays beside work at ${width}px`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 620 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "inline", width, height: 620 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
        await page.locator(".cv-worked").first().hover();
        await page.waitForFunction(
          () => {
            const time = document.querySelector(".cv-turn-time");
            return time && getComputedStyle(time).opacity === "1";
          },
          undefined,
          { timeout: 5_000 },
        );
        const geometry = await page.evaluate(() => {
          const worked = document.querySelector(".cv-worked")!;
          const box = (node: Element) => {
            const r = node.getBoundingClientRect();
            return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
          };
          return {
            worked: box(worked),
            label: box(worked.querySelector(".cv-worked__label")!),
            times: [...document.querySelectorAll(".cv-turn-time")].map((n) => ({ ...box(n), text: n.textContent })),
          };
        });
        console.log(JSON.stringify({ width, ...geometry }));
        if (process.env.CMUX_HOVER_CAPTURE_DIR)
          await page.screenshot({ path: path.join(process.env.CMUX_HOVER_CAPTURE_DIR, `hover-${width}.png`) });
        const time = geometry.times[0]!;
        expect(geometry.times.length).toBeGreaterThan(0);
        expect(time.x).toBeGreaterThanOrEqual(geometry.label.right);
        expect(time.y).toBeGreaterThanOrEqual(geometry.worked.y);
        expect(time.bottom).toBeLessThanOrEqual(geometry.worked.bottom);
      } finally {
        await page.close();
      }
    });
});
