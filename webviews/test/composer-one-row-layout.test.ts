// cmux-web-test-timeout: 180
// Leo 2026-10-29: "project and cloudness at the top ... and stop making them take up so much
// space." Claude's New Tab heads its box with the folder and machine, content-sized and side by
// side; the quiet row under the box keeps the mode and a trailing model.
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

  test("Claude heads the box with folder and machine; the quiet row keeps mode and model", async () => {
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
            if (!node) throw new Error(`Missing composer control: ${selector}`);
            const box = node.getBoundingClientRect();
            return {
              left: box.left,
              right: box.right,
              top: box.top,
              bottom: box.bottom,
              center: box.y + box.height / 2,
            };
          };
          return {
            folder: rect(
              ".nt-above .acpmux-location-leading > .acpmux-location-picker:first-child .acpmux-location-button",
            ),
            folderIcon: rect(
              ".nt-above .acpmux-location-leading > .acpmux-location-picker:first-child .acpmux-location-button svg",
            ),
            computer: rect('.nt-above .acpmux-location-picker[data-kind="computer"] .acpmux-location-button'),
            box: rect(".nt-box"),
            access: rect(".nt-foot .acpmux-access"),
            accessIcon: rect(".nt-foot .acpmux-access svg"),
            model: rect(".nt-foot .acpmux-model"),
            foot: rect(".nt-foot .acpmux-composer-foot"),
            footLocation: Boolean(document.querySelector(".nt-foot .acpmux-location-picker")),
          };
        });
        // Folder then machine, over the box, one line, one small gap, sized to their names.
        expect(layout.footLocation).toBe(false);
        expect(layout.folder.bottom).toBeLessThanOrEqual(layout.box.top);
        expect(layout.box.top - layout.folder.bottom).toBeLessThanOrEqual(10);
        expect(layout.computer.left - layout.folder.right).toBeGreaterThanOrEqual(0);
        expect(layout.computer.left - layout.folder.right).toBeLessThanOrEqual(6);
        expect(Math.abs(layout.folder.center - layout.computer.center)).toBeLessThanOrEqual(0.5);
        expect(layout.computer.right - layout.folder.left).toBeLessThan((layout.box.right - layout.box.left) / 2);
        // The strip's first icon stands on the quiet row's icon column.
        expect(Math.abs(layout.folderIcon.left - layout.accessIcon.left)).toBeLessThanOrEqual(2);
        // The quiet row: the mode, then the model on its trailing edge.
        expect(layout.access.right).toBeLessThanOrEqual(layout.model.left + 1);
        expect(Math.abs(layout.model.right - layout.foot.right)).toBeLessThanOrEqual(1);
        expect(Math.abs(layout.access.center - layout.model.center)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    }
  });
});
