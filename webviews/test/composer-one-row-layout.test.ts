// cmux-web-test-timeout: 180
// Claude's New Tab (2026-10-30, a sketch with arrows): folder and computer head the box, top left;
// the quiet row under it holds the mode on the left and the model on the trailing edge.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-one-row-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "newtab-claude" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("Claude puts the location above the box and the mode before a trailing model under it", async () => {
    for (const width of [420, 760]) {
      const page = await browser.newPage({ viewport: { width, height: 520 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant: "newtab-claude", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined);
        await page.evaluate(() => document.fonts.ready);
        const layout = await page.evaluate(() => {
          const rect = (selector: string) => {
            const node = document.querySelector<HTMLElement>(selector);
            if (!node) throw new Error(`Missing footer control: ${selector}`);
            const box = node.getBoundingClientRect();
            return { left: box.left, right: box.right, center: box.y + box.height / 2 };
          };
          return {
            folder: rect(".nt-above .acpmux-location-leading > .acpmux-location-picker:first-child"),
            computer: rect('.nt-above .acpmux-location-picker[data-kind="computer"]'),
            access: rect(".nt-foot .acpmux-access"),
            model: rect(".nt-foot .acpmux-model"),
            foot: rect(".nt-foot .acpmux-composer-foot"),
            footLocation: Boolean(document.querySelector(".nt-foot .acpmux-location-picker")),
          };
        });
        expect(layout.footLocation).toBe(false);
        expect(layout.folder.right).toBeLessThanOrEqual(layout.computer.left + 1);
        expect(Math.abs(layout.folder.center - layout.computer.center)).toBeLessThanOrEqual(1);
        // The strip heads the box; the mode and model share the row under it.
        expect(layout.computer.center).toBeLessThan(layout.foot.center);
        expect(layout.access.right).toBeLessThanOrEqual(layout.model.left + 1);
        expect(Math.abs(layout.model.right - layout.foot.right)).toBeLessThanOrEqual(1);
        expect(Math.abs(layout.access.center - layout.model.center)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    }
  });
});
