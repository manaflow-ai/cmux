// l10n-allow-file: synthetic gallery messages only.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("queued-message-copy-gutter-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.queued-agent-messages";
  let vite: ViteDevServer;
  let browser: Browser;

  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (width: number): Promise<Page> => {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "menu" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    if (width < 500) await page.evaluate(() => (document.documentElement.style.zoom = "1.25"));
    await page.locator('.cv-incoming[data-queued-message]').waitFor();
    return page;
  };

  for (const width of [760, 360]) {
    test(`queued-message header keeps its copy gutter at ${width}px`, async () => {
      const page = await open(width);
      const layout = await page.locator('.cv-incoming[data-queued-message]').first().evaluate((card) => {
        const line = card.querySelector<HTMLElement>(".cv-received__line")!;
        const note = card.querySelector<HTMLElement>(".cv-received__queued")!;
        const copy = card.closest<HTMLElement>(".acpmux-row")?.querySelector<HTMLElement>(".acpmux-row__copy");
        const lineBox = line.getBoundingClientRect();
        const noteBox = note.getBoundingClientRect();
        const copyBox = copy?.getBoundingClientRect();
        const overlap = copyBox
          ? Math.max(0, Math.min(noteBox.right, copyBox.right) - Math.max(noteBox.left, copyBox.left)) *
            Math.max(0, Math.min(noteBox.bottom, copyBox.bottom) - Math.max(noteBox.top, copyBox.top))
          : 0;
        return {
          copyPresent: Boolean(copyBox && copyBox.width > 0 && copyBox.height > 0),
          gutter: lineBox.right - noteBox.right,
          noteCopyOverlap: overlap,
        };
      });
      expect(layout.copyPresent).toBe(true);
      expect(layout.gutter).toBeGreaterThanOrEqual(48);
      expect(layout.noteCopyOverlap).toBe(0);
      await page.close();
    });
  }
});
