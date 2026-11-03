// cmux-web-test-timeout: 600
// aiforui.dev, Using AI at work: custom palettes and nested menus share the scroll-edge fade.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("palette-scroll-edge-fade.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["agent-pane.file-search", "long-results", '.acpmux-file-search [role="listbox"]'],
    ["pages.diff", "jump-file-overflow", ".jump-palette-list"],
    ["pages.diff", "branch-base-overflow", ".base-picker-list"],
    ["pages.diff", "committed-overflow", ".toolbar-submenu"],
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
    test(`${entry}/${variant}: soft edges follow overflow and scrolling`, async () => {
      const width = 1000;
      const height = 420;
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const list = page.locator(selector).first();
        await list.waitFor();
        expect(await list.evaluate((node) => node.scrollHeight > node.clientHeight + 1)).toBe(true);
        await list.evaluate((node) => {
          node.scrollTop = 0;
        });
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.hasAttribute("data-fade-bottom"),
          selector,
          { timeout: 5_000 },
        );
        expect(await list.getAttribute("data-fade-top")).toBeNull();
        expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).not.toBe("none");

        await list.evaluate((node) => {
          node.scrollTop = (node.scrollHeight - node.clientHeight) / 2;
        });
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.hasAttribute("data-fade-top"),
          selector,
        );
        expect(await list.getAttribute("data-fade-bottom")).not.toBeNull();

        if (process.env.FAST_CHECKS_OUT) {
          await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `${entry}-${variant}-overflow.png`) });
        }
        await list.evaluate((node) => {
          node.scrollTop = node.scrollHeight;
        });
        await page.waitForFunction(
          (selector) => !document.querySelector(selector)?.hasAttribute("data-fade-bottom"),
          selector,
        );
        expect(await list.getAttribute("data-fade-top")).not.toBeNull();

        if (entry === "agent-pane.file-search") {
          await page.locator(".acpmux-file-search input").fill("");
          await page.waitForFunction((selector) => {
            const node = document.querySelector(selector);
            return (
              node &&
              node.scrollHeight <= node.clientHeight &&
              !node.hasAttribute("data-fade-top") &&
              !node.hasAttribute("data-fade-bottom")
            );
          }, selector);
        }
        if (variant === "committed-overflow") expect(await page.locator(".source-menu").isVisible()).toBe(true);

        // The shared accessibility setting removes the mask without changing the scroll range.
        await page.evaluate(() => {
          document.documentElement.dataset.reduceTransparency = "true";
        });
        expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).toBe("none");
      } finally {
        await page.close();
      }
    });
  }
});
