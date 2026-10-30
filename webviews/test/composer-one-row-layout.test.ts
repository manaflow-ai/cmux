// cmux-web-test-timeout: 180
// Leo: "the claw thing should be one single row". Location and mode lead Claude's New Tab
// footer, while the model keeps the trailing edge; Codex retains its tray above the box.
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

  test("Claude keeps location and mode before a trailing model at narrow and normal widths", async () => {
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
            folder: rect(".nt-foot .acpmux-location-leading > .acpmux-location-picker:first-child"),
            computer: rect('.nt-foot .acpmux-location-picker[data-kind="computer"]'),
            access: rect(".nt-foot .acpmux-access"),
            model: rect(".nt-foot .acpmux-model"),
            foot: rect(".nt-foot .acpmux-composer-foot"),
            hasTopStrip: Boolean(document.querySelector(".nt-above")),
          };
        });
        expect(layout.hasTopStrip).toBe(false);
        expect(layout.folder.right).toBeLessThanOrEqual(layout.computer.left + 1);
        expect(layout.computer.right).toBeLessThanOrEqual(layout.access.left + 1);
        expect(layout.access.right).toBeLessThanOrEqual(layout.model.left + 1);
        expect(Math.abs(layout.model.right - layout.foot.right)).toBeLessThanOrEqual(1);
        const centers = [layout.folder, layout.computer, layout.access, layout.model].map((box) => box.center);
        expect(Math.max(...centers) - Math.min(...centers)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    }
  });
});
