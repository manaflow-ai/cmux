// l10n-allow-file: gallery fixture filenames used by a layout regression.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("attachment-file-chip-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
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
    await warmGalleryFrame(vite, "agent-pane.file-attachment", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("both file chips keep the extension and size inside their bounds at 320px", async () => {
    const page = await browser.newPage({ viewport: { width: 320, height: 600 } });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.file-attachment", {
          variant: "balanced",
          width: 320,
          height: 600,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const chips = page.locator(".acpmux-file-chip[data-file-type=pem]");
      expect(await chips.count()).toBe(2);
      for (const chip of await chips.all()) {
        const box = (await chip.boundingBox())!;
        expect(
          await chip.evaluate((node) =>
            parseFloat(getComputedStyle(node.closest(".acpmux-attachment") ?? node).borderTopLeftRadius),
          ),
        ).toBeGreaterThanOrEqual(4);
        expect(await chip.evaluate((node) => parseFloat(getComputedStyle(node).columnGap))).toBeGreaterThanOrEqual(4);
        for (const selector of [".acpmux-file-chip__tail", ".acpmux-file-chip__size"]) {
          const part = (await chip.locator(selector).boundingBox())!;
          expect(part.x).toBeGreaterThanOrEqual(box.x);
          expect(part.x + part.width).toBeLessThanOrEqual(box.x + box.width + 1);
        }
        expect(box.x + box.width).toBeLessThanOrEqual(320);
        expect(await chip.innerText()).not.toContain("Sent as file path");
      }
    } finally {
      await page.close();
    }
  });
});
