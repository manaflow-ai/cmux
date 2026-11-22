// cmux-web-test-timeout: 600
// aiforui.dev, Using AI at work: capped custom lists disclose rows beyond their scroll edges.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("custom-list-scroll-edge-fade.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["viewer-empty.path-picker", "overflowing", ".ve-picker-list"],
    ["viewer-empty.path-picker", "virtual-overflow", ".ve-picker-list"],
    ["agent-pane.checkpoint-review", "candidates-overflow", ".acpmux-checkpoint-candidates"],
    ["agent-pane.checkpoint-review", "skipped-overflow", ".acpmux-checkpoint-review details ul"],
    ["pages.settings", "agents-registry-overflow", "[data-agents-registry] > div:last-child"],
  ] as const;

  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const [entry, variant] of scenes) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  }, 240_000);

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant, selector] of scenes) {
    test(`${entry}#${variant}: rows fade at overflowing edges without masking their shell`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 720 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 1000, height: 720 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const list = page.locator(selector).first();
        await list.waitFor();
        expect(await list.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeGreaterThan(1);
        await list.evaluate((node) => {
          node.scrollTop = 0;
        });
        await page.waitForFunction(
          (selector) => {
            const list = document.querySelector(selector);
            return list?.hasAttribute("data-fade-bottom") && !list.hasAttribute("data-fade-top");
          },
          selector,
          { timeout: 5_000 },
        );
        expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).not.toBe("none");
        expect(
          await list.evaluate((node) => {
            for (let parent = node.parentElement; parent; parent = parent.parentElement) {
              if (parent.classList.contains("ui-glass")) return getComputedStyle(parent).maskImage;
            }
            return "none";
          }),
        ).toBe("none");
        await list.evaluate((node) => {
          node.scrollTop = (node.scrollHeight - node.clientHeight) / 2;
        });
        await page.waitForFunction((selector) => {
          const list = document.querySelector(selector);
          return list?.hasAttribute("data-fade-top") && list.hasAttribute("data-fade-bottom");
        }, selector);
        await list.evaluate((node) => {
          node.scrollTop = node.scrollHeight;
        });
        await page.waitForFunction((selector) => {
          const list = document.querySelector(selector);
          return list?.hasAttribute("data-fade-top") && !list.hasAttribute("data-fade-bottom");
        }, selector);
      } finally {
        await page.close();
      }
    });
  }
});
